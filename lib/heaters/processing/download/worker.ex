defmodule Heaters.Processing.Download.Worker do
  @moduledoc """
  Download Worker for source video ingestion.

  Orchestrates the initial download phase of the video processing pipeline:
  - Downloads videos from URLs using yt-dlp with quality-focused strategy
  - Applies conditional normalization for primary downloads (fixes merge issues)
  - Stores original files in S3 for downstream processing
  - Chains to encoding stage for pipeline optimization

  ## Architecture

  This worker follows the Elixir-orchestrated pattern:
  - **Configuration**: Provided by `YtDlpConfig` and `FFmpegConfig` modules
  - **Execution**: Python task receives complete config and focuses on execution
  - **State Management**: Elixir handles all state transitions and business logic

  See `YtDlpConfig` for yt-dlp configuration details and quality requirements.
  """

  use Heaters.Pipeline.WorkerBehavior,
    queue: :media_processing,
    # 10 minutes with source_video_id uniqueness only
    unique: [period: 600, fields: [:args], keys: [:source_video_id]]

  alias Heaters.Media.Videos
  alias Heaters.Processing.Support.PythonRunner, as: PyRunner
  alias Heaters.Storage.PipelineCache.TempCache
  alias Heaters.Processing.Download.{Core, YtDlpConfig}
  alias Heaters.Processing.Support.ResultBuilder
  alias Heaters.Storage.S3.Core, as: S3

  alias Heaters.Pipeline.WorkerBehavior

  require Logger

  # Suppress dialyzer warnings for PyRunner calls when environment is not configured.
  #
  # JUSTIFICATION: PyRunner requires DEV_DATABASE_URL and DEV_S3_BUCKET_NAME environment
  # variables. When these are not set (e.g., in unconfigured development environments),
  # PyRunner will always fail with {:error, "Environment variable ... not set"}.
  #
  # This makes success patterns and their dependent functions (convert_keys_to_atoms,
  # handle_temp_cache_download_completion) genuinely unreachable in such environments.
  #
  # In properly configured environments, these functions WILL be called and succeed.
  @dialyzer {:nowarn_function,
             [
               handle_ingest_work: 1,
               convert_keys_to_atoms: 1,
               safe_string_to_atom: 1,
               handle_temp_cache_download_completion: 2,
               get_file_size: 1,
               get_format_info: 1,
               get_quality_metrics: 1,
               build_resolution_string: 2
             ]}

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [handle_work: 1]}

  @impl WorkerBehavior
  def handle_work(%{"source_video_id" => source_video_id} = args) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      case check_idempotency(source_video) do
        :ok ->
          handle_ingest_work(args)

        {:error, :already_processed} ->
          WorkerBehavior.handle_already_processed("Source video", source_video_id)
      end
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Source video", source_video_id)
    end
  end

  defp handle_ingest_work(%{"source_video_id" => source_video_id}) do
    Logger.info("DownloadWorker: Starting download for source_video_id: #{source_video_id}")

    with {:ok, source_video} <- Videos.get_source_video(source_video_id),
         {:ok, updated_video} <- ensure_downloading_state(source_video) do
      Logger.info(
        "DownloadWorker: Running PyRunner for source_video_id: #{source_video_id}, URL: #{updated_video.original_url}"
      )

      # Python task receives complete configuration from Elixir
      # All yt-dlp options, format strategies, and normalization config
      # are provided by YtDlpConfig and FFmpegConfig modules
      download_config = YtDlpConfig.get_download_config()

      # Validate configuration before sending to Python
      :ok = YtDlpConfig.validate_config!(download_config)

      # Generate timestamp for consistent naming
      timestamp = generate_timestamp()

      py_args = %{
        source_video_id: updated_video.id,
        input_source: updated_video.original_url,
        # Pass timestamp instead of pre-generated path - we'll generate the final path
        # after we get the real title from yt-dlp
        timestamp: timestamp,
        # Always use temp cache - Elixir handles S3 upload with native operations
        use_temp_cache: true,
        # Complete yt-dlp configuration from YtDlpConfig (validated)
        download_config: download_config,
        # FFmpeg normalization arguments from FFmpegConfig
        normalize_args: Heaters.Processing.Support.FFmpeg.Config.get_args(:download_normalization)
      }

      case PyRunner.run_python_task("download", py_args, timeout: :timer.minutes(20)) do
        {:ok, result} ->
          Logger.info(
            "DownloadWorker: PyRunner succeeded for source_video_id: #{source_video_id}, result: #{inspect(result)}"
          )

          # Elixir handles the state transition and metadata update
          # Convert string keys to atom keys for the metadata (recursively)
          metadata = convert_keys_to_atoms(result)

          # Always handle temp cache completion since Python no longer uploads to S3
          # Python returns local_filepath and Elixir handles the S3 upload
          completion_result = handle_temp_cache_download_completion(source_video_id, metadata)

          case completion_result do
            {:ok, updated_video} ->
              Logger.info(
                "DownloadWorker: Successfully completed download for source_video_id: #{source_video_id}"
              )

              # Chain directly to next stage using centralized pipeline configuration
              :ok = Heaters.Pipeline.Config.maybe_chain_next_job(__MODULE__, updated_video)
              Logger.info("DownloadWorker: Successfully chained to next pipeline stage")

              # Build structured result with rich metadata
              download_result =
                ResultBuilder.download_success(source_video_id, updated_video.filepath, %{
                  title: updated_video.title,
                  duration_seconds: updated_video.duration_seconds,
                  file_size_bytes: get_file_size(result),
                  format_info: get_format_info(result),
                  quality_metrics: get_quality_metrics(result),
                  metadata: metadata
                })

              # Log structured result for observability
              ResultBuilder.log_result(__MODULE__, download_result)
              download_result

            {:error, reason} ->
              Logger.error("DownloadWorker: Failed to update video metadata: #{inspect(reason)}")
              ResultBuilder.download_error(source_video_id, reason)
          end

        {:error, reason} ->
          # If the python script fails, we use the new state management to record the error
          Logger.error(
            "DownloadWorker: PyRunner failed for source_video_id: #{source_video_id}, reason: #{inspect(reason)}"
          )

          case Core.mark_failed(updated_video, :download_failed, reason) do
            {:ok, _} ->
              {:error, reason}

            {:error, db_error} ->
              Logger.error("DownloadWorker: Failed to mark video as failed: #{inspect(db_error)}")
              {:error, reason}
          end
      end
    else
      {:error, reason} ->
        Logger.error(
          "DownloadWorker: Failed to prepare for download for source video #{source_video_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Helper function to ensure video is in downloading state, handling resumable processing
  defp ensure_downloading_state(source_video) do
    case source_video.ingest_state do
      :downloading ->
        Logger.info(
          "DownloadWorker: Video #{source_video.id} already in downloading state, resuming"
        )

        {:ok, source_video}

      _ ->
        # Transition to downloading state for new/failed videos
        Core.start_downloading(source_video.id)
    end
  end

  # Idempotency Check: Ensures we don't re-process completed work.
  # Now supports resumable processing of interrupted jobs.
  defp check_idempotency(%{ingest_state: :new}), do: :ok
  # Allow resuming interrupted jobs
  defp check_idempotency(%{ingest_state: :downloading}), do: :ok
  defp check_idempotency(%{ingest_state: :download_failed}), do: :ok
  defp check_idempotency(_), do: {:error, :already_processed}

  defp convert_keys_to_atoms(map) when is_map(map) do
    for {key, value} <- map, into: %{} do
      {safe_string_to_atom(key), convert_keys_to_atoms(value)}
    end
  end

  defp convert_keys_to_atoms(list) when is_list(list) do
    for item <- list, do: convert_keys_to_atoms(item)
  end

  defp convert_keys_to_atoms(other), do: other

  # Safe atom conversion with allowlist for expected metadata keys
  defp safe_string_to_atom(key) when is_binary(key) do
    case key do
      # Known metadata keys from Python download task
      "filepath" -> :filepath
      "local_filepath" -> :local_filepath
      "title" -> :title
      "duration" -> :duration
      "filesize" -> :filesize
      "format_id" -> :format_id
      "ext" -> :ext
      "width" -> :width
      "height" -> :height
      "fps" -> :fps
      "vcodec" -> :vcodec
      "acodec" -> :acodec
      "format" -> :format
      "resolution" -> :resolution
      "filesize_approx" -> :filesize_approx
      # Nested metadata structure
      "metadata" -> :metadata
      "duration_seconds" -> :duration_seconds
      "file_size_bytes" -> :file_size_bytes
      "status" -> :status
      # Keep unknown keys as strings to avoid atom table pollution
      _ -> key
    end
  end

  defp safe_string_to_atom(key), do: key

  # Handle download completion when using temp cache
  # Uses pattern matching to validate required paths before proceeding
  defp handle_temp_cache_download_completion(source_video_id, metadata) do
    title = get_in(metadata, [:metadata, :title]) || "video_#{source_video_id}"
    timestamp = get_in(metadata, [:metadata, :timestamp]) || generate_timestamp()
    s3_key = Heaters.Storage.S3.Paths.generate_original_path(title, timestamp, ".mp4")

    with {:ok, local_path} <- extract_local_path(metadata),
         :ok <- Logger.info("DownloadWorker: Starting native Elixir S3 upload for #{s3_key}"),
         {:ok, ^s3_key} <- upload_to_s3(local_path, s3_key) do
      Logger.info("DownloadWorker: Successfully uploaded to S3: #{s3_key}")
      cache_and_complete(source_video_id, metadata, s3_key, local_path)
    else
      {:error, :missing_local_path} ->
        Logger.error(
          "DownloadWorker: Missing local_filepath in metadata: #{inspect(Map.keys(metadata))}"
        )

        {:error, "Missing required file paths from Python download task"}

      {:error, upload_reason} ->
        Logger.error("DownloadWorker: S3 upload failed: #{inspect(upload_reason)}")
        {:error, "S3 upload failed: #{inspect(upload_reason)}"}
    end
  end

  # Extract local path from metadata, returning error tuple if missing
  defp extract_local_path(%{local_filepath: local_path}) when is_binary(local_path) do
    {:ok, local_path}
  end

  defp extract_local_path(_metadata), do: {:error, :missing_local_path}

  # Upload file to S3 with progress reporting
  defp upload_to_s3(local_path, s3_key) do
    S3.upload_file_with_progress(local_path, s3_key,
      operation_name: "Download",
      storage_class: "STANDARD"
    )
  end

  # Cache the file and complete the download, handling cache failures gracefully
  defp cache_and_complete(source_video_id, metadata, s3_key, local_path) do
    case TempCache.put(s3_key, local_path) do
      {:ok, _cached_path} ->
        Logger.info("DownloadWorker: Cached download result for pipeline chaining")

      {:error, reason} ->
        Logger.warning("DownloadWorker: Failed to cache download result: #{inspect(reason)}")
    end

    # Update database with correct S3 path (proceed regardless of cache success)
    updated_metadata = Map.put(metadata, :filepath, s3_key)
    Core.complete_downloading(source_video_id, updated_metadata)
  end

  # Generate timestamp for unique file naming (matches S3.Paths format)
  defp generate_timestamp do
    DateTime.utc_now()
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
    |> String.replace("-", "")
    |> String.replace(":", "")
    |> String.replace(" ", "_")
  end

  # Metadata extraction helpers for structured results
  defp get_file_size(result) do
    result["filesize"] || result["filesize_approx"]
  end

  defp get_format_info(result) do
    %{
      format_id: result["format_id"],
      ext: result["ext"],
      width: result["width"],
      height: result["height"],
      fps: result["fps"],
      vcodec: result["vcodec"],
      acodec: result["acodec"],
      resolution: result["resolution"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp get_quality_metrics(result) do
    %{
      resolution: build_resolution_string(result["width"], result["height"]),
      fps: result["fps"],
      codec: result["vcodec"],
      format_note: result["format"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp build_resolution_string(nil, _), do: nil
  defp build_resolution_string(_, nil), do: nil
  defp build_resolution_string(width, height), do: "#{width}x#{height}"
end
