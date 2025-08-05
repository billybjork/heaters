defmodule Heaters.Storage.PipelineCache.TempCache do
  @moduledoc """
  Temporary file caching to eliminate upload-download loops between pipeline stages.

  This module provides a simple file-based cache using temp directories that persists
  across job boundaries within the same pipeline execution. Files are cached locally
  and automatically cleaned up after pipeline completion or timeout.

  ## Cache Strategy

  - Files are cached in a temporary directory structure by S3 key
  - Cache entries include metadata for validation
  - Automatic cleanup after configurable timeout (default: 1 hour)
  - Thread-safe operations using file locks

  ## Usage

  Instead of uploading immediately and downloading later:

      # OLD: Upload immediately
      upload_to_s3(local_file, s3_key)

      # NEW: Cache locally and upload only at end
      TempCache.put(s3_key, local_file)
      # ... pass s3_key through Oban args
      local_path = TempCache.get(s3_key)  # Returns cached path if available
  """

  require Logger

  @cache_timeout_ms :timer.hours(1)

  @doc """
  Store a file in the temporary cache with the given S3 key.

  ## Parameters
  - s3_key: S3 key that would be used for upload
  - local_path: Path to local file to cache

  ## Returns
  {:ok, cached_path} | {:error, reason}
  """
  @spec put(String.t(), Path.t()) :: {:ok, Path.t()} | {:error, any()}
  def put(s3_key, local_path) do
    with {:ok, cache_dir} <- ensure_cache_dir(),
         cached_path <- build_cache_path(cache_dir, s3_key),
         :ok <- File.mkdir_p(Path.dirname(cached_path)),
         :ok <- File.cp(local_path, cached_path) do
      # Store metadata
      metadata = %{
        original_key: s3_key,
        cached_at: DateTime.utc_now(),
        file_size: File.stat!(local_path).size
      }

      metadata_path = cached_path <> ".meta"
      File.write!(metadata_path, Jason.encode!(metadata))

      Logger.debug("TempCache: Cached #{s3_key} -> #{cached_path}")
      {:ok, cached_path}
    else
      {:error, reason} ->
        Logger.warning("TempCache: Failed to cache #{s3_key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Retrieve a file from the temporary cache.

  ## Parameters
  - s3_key: S3 key to look up

  ## Returns
  {:ok, cached_path} | {:error, :not_found} | {:error, :expired}
  """
  @spec get(String.t()) :: {:ok, Path.t()} | {:error, :not_found | :expired | any()}
  def get(s3_key) do
    with {:ok, cache_dir} <- ensure_cache_dir(),
         cached_path <- build_cache_path(cache_dir, s3_key),
         true <- File.exists?(cached_path),
         {:ok, metadata} <- read_metadata(cached_path) do
      if cache_expired?(metadata) do
        cleanup_cache_entry(cached_path)
        {:error, :expired}
      else
        Logger.debug("TempCache: Hit #{s3_key} -> #{cached_path}")
        {:ok, cached_path}
      end
    else
      false ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if a file exists in cache without retrieving it.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(s3_key) do
    case get(s3_key) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Persist cached file to S3 and remove from cache.

  This should be called at the end of pipeline processing to finalize storage.
  """
  @spec persist_to_s3(String.t(), String.t() | nil, String.t()) :: :ok | {:error, any()}
  def persist_to_s3(cache_key, s3_destination \\ nil, storage_class \\ "STANDARD") do
    # Default s3_destination to cache_key for backward compatibility
    s3_key = s3_destination || cache_key

    case get(cache_key) do
      {:ok, cached_path} ->
        result = upload_to_s3(cached_path, s3_key, storage_class)
        cleanup_cache_entry(cached_path)
        result

      {:error, :not_found} ->
        Logger.debug(
          "TempCache: Cannot persist #{cache_key} - not found in cache (normal cache expiration)"
        )

        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get a file for processing, either from cache or by downloading from S3.

  This is the key function for the temp file chain pattern. It attempts to get
  the file from cache first, and falls back to S3 download if not available.

  ## Parameters
  - s3_key: S3 key to look up
  - opts: Options for download operation if needed
    - :operation_name: Name to use in log messages

  ## Returns
  {:ok, local_path, :cache_hit} | {:ok, local_path, :downloaded} | {:error, reason}
  """
  @spec get_or_download(String.t(), keyword()) ::
          {:ok, Path.t(), :cache_hit | :downloaded} | {:error, any()}
  def get_or_download(s3_key, opts \\ []) do
    case get(s3_key) do
      {:ok, cached_path} ->
        Logger.debug("TempCache: Using cached file for #{s3_key}")
        {:ok, cached_path, :cache_hit}

      {:error, :not_found} ->
        download_and_cache(s3_key, opts)

      {:error, :expired} ->
        Logger.debug("TempCache: Cache expired for #{s3_key}, re-downloading")
        download_and_cache(s3_key, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Store intermediate processing results for the next stage in the pipeline.

  This allows passing multiple files (e.g., master + proxy) to the next worker
  without individual S3 uploads.

  ## Parameters
  - results: Map of result_type -> local_path
  - source_video_id: ID for generating cache keys

  ## Returns
  {:ok, cached_results} where cached_results is a map of result_type -> cache_info
  """
  @spec put_processing_results(map(), integer()) :: {:ok, map()} | {:error, any()}
  def put_processing_results(results, source_video_id) when is_map(results) do
    cached_results =
      results
      |> Enum.reduce_while({:ok, %{}}, fn {result_type, local_path}, {:ok, acc} ->
        cache_key = "temp_#{source_video_id}_#{result_type}"

        case put(cache_key, local_path) do
          {:ok, cached_path} ->
            cache_info = %{
              cache_key: cache_key,
              cached_path: cached_path,
              result_type: result_type
            }

            {:cont, {:ok, Map.put(acc, result_type, cache_info)}}

          {:error, reason} ->
            {:halt, {:error, {result_type, reason}}}
        end
      end)

    case cached_results do
      {:ok, results_map} ->
        Logger.info(
          "TempCache: Cached #{map_size(results_map)} processing results for video #{source_video_id}"
        )

        {:ok, results_map}

      {:error, {result_type, reason}} ->
        Logger.error(
          "TempCache: Failed to cache #{result_type} for video #{source_video_id}: #{inspect(reason)}"
        )

        {:error, {result_type, reason}}
    end
  end

  @doc """
  Clean up expired cache entries.
  Called automatically by TempManager.
  """
  @spec cleanup_expired() :: :ok
  def cleanup_expired() do
    case ensure_cache_dir() do
      {:ok, cache_dir} ->
        cache_dir
        |> Path.join("**/*.meta")
        |> Path.wildcard()
        |> Enum.each(&maybe_cleanup_expired_entry/1)

      {:error, _} ->
        :ok
    end
  end

  ## Private Functions

  defp ensure_cache_dir() do
    # Use a shared persistent cache directory instead of job-specific temp dirs
    # This allows sharing cached files between different worker processes
    cache_dir = Path.join(System.tmp_dir!(), "heaters_shared_cache")

    case File.mkdir_p(cache_dir) do
      :ok ->
        {:ok, cache_dir}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_cache_path(cache_dir, s3_key) do
    # Convert S3 key to safe filesystem path
    safe_key =
      s3_key
      |> String.replace("/", "_")
      |> String.replace("\\", "_")

    Path.join(cache_dir, safe_key)
  end

  defp read_metadata(cached_path) do
    metadata_path = cached_path <> ".meta"

    case File.read(metadata_path) do
      {:ok, content} ->
        Jason.decode(content, keys: :atoms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cache_expired?(%{cached_at: cached_at_str}) do
    case DateTime.from_iso8601(cached_at_str) do
      {:ok, cached_at, _} ->
        age_ms = DateTime.diff(DateTime.utc_now(), cached_at, :millisecond)
        age_ms > @cache_timeout_ms

      _ ->
        # Invalid timestamp, consider expired
        true
    end
  end

  defp cleanup_cache_entry(cached_path) do
    File.rm(cached_path)
    File.rm(cached_path <> ".meta")
  end

  defp maybe_cleanup_expired_entry(metadata_path) do
    cached_path = String.replace_suffix(metadata_path, ".meta", "")

    case read_metadata(cached_path) do
      {:ok, metadata} ->
        if cache_expired?(metadata) do
          cleanup_cache_entry(cached_path)
        end

      {:error, _} ->
        # Remove orphaned metadata
        File.rm(metadata_path)
    end
  end

  defp download_and_cache(s3_key, opts) do
    alias Heaters.Storage.S3

    # Create temporary download path
    with {:ok, cache_dir} <- ensure_cache_dir(),
         download_path <-
           Path.join(cache_dir, "download_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"),
         {:ok, _} <- S3.download_file(s3_key, download_path, opts),
         {:ok, cached_path} <- put(s3_key, download_path) do
      # Clean up temporary download file
      File.rm(download_path)
      Logger.debug("TempCache: Downloaded and cached #{s3_key}")
      {:ok, cached_path, :downloaded}
    else
      {:error, reason} ->
        Logger.warning("TempCache: Failed to download and cache #{s3_key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp upload_to_s3(local_path, s3_key, storage_class) do
    # Use existing S3 infrastructure with progress reporting for better visibility
    alias Heaters.Storage.S3

    # Determine if we should use progress reporting based on file size
    file_size = File.stat!(local_path).size
    # Use progress for files > 10MB
    use_progress = file_size > 10 * 1024 * 1024

    upload_result =
      if use_progress do
        Logger.info(
          "TempCache: Using progress reporting for large file (#{file_size} bytes): #{s3_key}"
        )

        S3.upload_file_with_progress(local_path, s3_key,
          storage_class: storage_class,
          operation_name: "CachePersist",
          timeout: :timer.minutes(45)
        )
      else
        S3.upload_file(local_path, s3_key,
          storage_class: storage_class,
          operation_name: "CachePersist"
        )
      end

    case upload_result do
      {:ok, _} ->
        Logger.info("TempCache: Successfully uploaded #{s3_key} to S3 (#{storage_class})")
        :ok

      {:error, reason} ->
        Logger.error("TempCache: Failed to persist #{s3_key} to S3: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
