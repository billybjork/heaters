defmodule Heaters.Infrastructure.CacheArgs do
  @moduledoc """
  Helper module for handling cached local paths in Python task arguments.

  This module provides utilities to check for locally cached files and modify
  task arguments to use local paths instead of S3 paths when available,
  eliminating unnecessary downloads.
  """

  alias Heaters.Infrastructure.TempCache
  require Logger

  @doc """
  Resolve S3 paths to local cached paths if available.

  Takes a map of task arguments and checks if any S3 paths have cached
  local equivalents. If found, adds a corresponding `*_local_path` key.

  ## Examples

      args = %{
        source_video_path: "source_videos/video.mp4",
        proxy_video_path: "proxies/video_proxy.mp4"
      }

      resolved = CacheArgs.resolve_cached_paths(args)
      # Returns:
      # %{
      #   source_video_path: "source_videos/video.mp4",
      #   source_video_local_path: "/tmp/cached_video.mp4",  # if cached
      #   proxy_video_path: "proxies/video_proxy.mp4"
      # }
  """
  @spec resolve_cached_paths(map()) :: map()
  def resolve_cached_paths(args) when is_map(args) do
    args
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      acc = Map.put(acc, key, value)

      # Check if this looks like an S3 path key
      if is_s3_path_key?(key) do
        case TempCache.get(value) do
          {:ok, local_path} ->
            local_key = get_local_path_key(key)
            Logger.debug("CacheArgs: Using cached path #{value} -> #{local_path}")
            Map.put(acc, local_key, local_path)

          {:error, :not_found} ->
            acc

          {:error, :expired} ->
            Logger.debug("CacheArgs: Cache expired for #{value}")
            acc

          {:error, reason} ->
            Logger.warning(
              "CacheArgs: Failed to get cached path for #{value}: #{inspect(reason)}"
            )

            acc
        end
      else
        acc
      end
    end)
  end

  @doc """
  Cache the outputs from a task for use by subsequent tasks.

  Takes task results and caches any files that might be used by later stages.
  Returns updated results with cache status information.
  """
  @spec cache_task_outputs(map()) :: map()
  def cache_task_outputs(%{"status" => "success"} = results) do
    cached_results =
      results
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        acc = Map.put(acc, key, value)

        # Cache files that end with "_path" and have S3 keys
        if String.ends_with?(to_string(key), "_path") and is_binary(value) do
          case extract_temp_file_path(results, key) do
            {:ok, local_path} ->
              case TempCache.put(value, local_path) do
                {:ok, cached_path} ->
                  Logger.debug("CacheArgs: Cached #{value} -> #{cached_path}")
                  Map.put(acc, "#{key}_cached", true)

                {:error, reason} ->
                  Logger.warning("CacheArgs: Failed to cache #{value}: #{inspect(reason)}")
                  Map.put(acc, "#{key}_cached", false)
              end

            {:error, :not_available} ->
              # No local path available, this is fine for non-temp-cache tasks
              Logger.debug("CacheArgs: No local path available for #{key}")
              acc

            {:error, reason} ->
              Logger.warning(
                "CacheArgs: Cannot extract local path for #{key}: #{inspect(reason)}"
              )

              Map.put(acc, "#{key}_cached", false)
          end
        else
          acc
        end
      end)

    cached_results
  end

  def cache_task_outputs(results), do: results

  @doc """
  Finalize cached files to S3 storage.

  Should be called at the end of pipeline processing to upload cached files
  to their final S3 destinations.
  """
  @spec finalize_cached_files([String.t()]) :: :ok
  def finalize_cached_files(cache_keys) when is_list(cache_keys) do
    cache_keys
    |> Enum.each(fn cache_key ->
      # For temp cache keys, we need to get the S3 destination from the cached file
      s3_destination = resolve_s3_destination(cache_key)

      case TempCache.finalize_to_s3(cache_key, s3_destination, "STANDARD") do
        :ok ->
          Logger.info("CacheArgs: Finalized #{cache_key} to #{s3_destination}")

        {:error, :not_found} ->
          # File wasn't cached, that's fine (may have been uploaded directly)
          Logger.debug("CacheArgs: Cache key #{cache_key} not found, skipping")

        {:error, reason} ->
          Logger.error("CacheArgs: Failed to finalize #{cache_key}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  ## Private Functions

  defp resolve_s3_destination(cache_key) do
    if String.starts_with?(cache_key, "temp_") do
      # Parse temp cache key to get source video ID and file type
      case parse_temp_cache_key(cache_key) do
        {:ok, source_video_id, file_type} ->
          # Query database for the actual S3 path
          get_s3_path_from_database(source_video_id, file_type)

        {:error, _} ->
          # Fallback to using cache key as destination
          cache_key
      end
    else
      # For S3 keys, use them directly
      cache_key
    end
  end

  defp parse_temp_cache_key("temp_" <> rest) do
    case String.split(rest, "_", parts: 2) do
      [id_str, file_type] ->
        case Integer.parse(id_str) do
          {source_video_id, ""} -> {:ok, source_video_id, file_type}
          _ -> {:error, :invalid_id}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp parse_temp_cache_key(_), do: {:error, :not_temp_key}

  defp get_s3_path_from_database(source_video_id, file_type) do
    case Heaters.Videos.Queries.get_source_video(source_video_id) do
      {:ok, source_video} ->
        case file_type do
          "proxy" -> source_video.proxy_filepath
          "master" -> source_video.master_filepath
          "source" -> source_video.filepath
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp is_s3_path_key?(key) do
    key_str = to_string(key)
    String.ends_with?(key_str, "_path") or String.ends_with?(key_str, "_video_path")
  end

  defp get_local_path_key(key) do
    key_str = to_string(key)
    base = String.replace_suffix(key_str, "_path", "")
    String.to_atom("#{base}_local_path")
  end

  defp extract_temp_file_path(results, key) do
    # Extract local file paths from Python task results for caching
    # Python tasks return local paths with "_local_path" suffix when using temp cache
    key_str = to_string(key)
    local_path_key = String.replace_suffix(key_str, "_path", "_local_path")

    case Map.get(results, local_path_key) do
      nil ->
        # Try alternative patterns that might be used by Python tasks
        alt_patterns = [
          "#{key_str}_local",
          "local_#{key_str}",
          "#{String.replace_suffix(key_str, "_path", "")}_local_path"
        ]

        case find_local_path_in_results(results, alt_patterns) do
          {:ok, local_path} -> {:ok, local_path}
          {:error, :not_found} -> {:error, :not_available}
        end

      local_path when is_binary(local_path) ->
        # Validate that the local path exists
        if File.exists?(local_path) do
          {:ok, local_path}
        else
          Logger.warning("CacheArgs: Local path #{local_path} does not exist")
          {:error, :file_not_found}
        end

      _ ->
        {:error, :invalid_path}
    end
  end

  # Helper to find local paths using alternative naming patterns
  defp find_local_path_in_results(results, patterns) when is_list(patterns) do
    case patterns do
      [] ->
        {:error, :not_found}

      [pattern | remaining] ->
        case Map.get(results, pattern) do
          nil ->
            find_local_path_in_results(results, remaining)

          local_path when is_binary(local_path) and local_path != "" ->
            if File.exists?(local_path) do
              {:ok, local_path}
            else
              find_local_path_in_results(results, remaining)
            end

          _ ->
            find_local_path_in_results(results, remaining)
        end
    end
  end
end
