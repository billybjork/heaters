defmodule Heaters.Storage.PipelineCache.CacheArgs do
  @moduledoc """
  Helper module for handling cached local paths in Python task arguments.

  This module provides utilities to check for locally cached files and modify
  task arguments to use local paths instead of S3 paths when available,
  eliminating unnecessary downloads.
  """

  alias Heaters.Media.Videos
  alias Heaters.Storage.PipelineCache.TempCache
  require Logger

  @doc """
  Resolve S3 paths to local cached paths if available.

  Takes a map of task arguments and checks if any S3 paths have cached
  local equivalents. If found, adds a corresponding `*_local_path` key.

  ## Examples

      args = %{
        source_video_path: "originals/video.mp4",
        proxy_video_path: "proxies/video_proxy.mp4"
      }

      resolved = CacheArgs.resolve_cached_paths(args)
      # Returns:
      # %{
      #   source_video_path: "originals/video.mp4",
      #   source_video_local_path: "/tmp/cached_video.mp4",  # if cached
      #   proxy_video_path: "proxies/video_proxy.mp4"
      # }
  """
  @spec resolve_cached_paths(map()) :: map()
  def resolve_cached_paths(args) when is_map(args) do
    Enum.reduce(args, %{}, fn {key, value}, acc ->
      acc = Map.put(acc, key, value)
      maybe_add_cached_local_path(acc, key, value)
    end)
  end

  defp maybe_add_cached_local_path(acc, key, value) do
    if s3_path_key?(key) do
      add_cached_local_path(acc, key, value)
    else
      acc
    end
  end

  defp add_cached_local_path(acc, key, s3_path) do
    case TempCache.get(s3_path) do
      {:ok, local_path} ->
        local_key = get_local_path_key(key)
        Logger.debug("CacheArgs: Using cached path #{s3_path} -> #{local_path}")
        Map.put(acc, local_key, local_path)

      {:error, :not_found} ->
        acc

      {:error, :expired} ->
        Logger.debug("CacheArgs: Cache expired for #{s3_path}")
        acc

      {:error, reason} ->
        Logger.warning("CacheArgs: Failed to get cached path for #{s3_path}: #{inspect(reason)}")
        acc
    end
  end

  @doc """
  Cache the outputs from a task for use by subsequent tasks.

  Takes task results and caches any files that might be used by later stages.
  Returns updated results with cache status information.
  """
  @spec cache_task_outputs(map()) :: map()
  def cache_task_outputs(%{"status" => "success"} = results) do
    Enum.reduce(results, %{}, fn {key, value}, acc ->
      acc = Map.put(acc, key, value)
      maybe_cache_path_value(acc, results, key, value)
    end)
  end

  def cache_task_outputs(results), do: results

  defp maybe_cache_path_value(acc, results, key, value)
       when is_binary(value) do
    if String.ends_with?(to_string(key), "_path") do
      cache_path_to_temp(acc, results, key, value)
    else
      acc
    end
  end

  defp maybe_cache_path_value(acc, _results, _key, _value), do: acc

  defp cache_path_to_temp(acc, results, key, s3_value) do
    case extract_temp_file_path(results, key) do
      {:ok, local_path} ->
        try_cache_file(acc, key, s3_value, local_path)

      {:error, :not_available} ->
        Logger.debug("CacheArgs: No local path available for #{key}")
        acc

      {:error, reason} ->
        Logger.warning("CacheArgs: Cannot extract local path for #{key}: #{inspect(reason)}")
        Map.put(acc, "#{key}_cached", false)
    end
  end

  defp try_cache_file(acc, key, s3_value, local_path) do
    case TempCache.put(s3_value, local_path) do
      {:ok, cached_path} ->
        Logger.debug("CacheArgs: Cached #{s3_value} -> #{cached_path}")
        Map.put(acc, "#{key}_cached", true)

      {:error, reason} ->
        Logger.warning("CacheArgs: Failed to cache #{s3_value}: #{inspect(reason)}")
        Map.put(acc, "#{key}_cached", false)
    end
  end

  @doc """
  Persist cached files to S3 storage.

  Should be called at the end of pipeline processing to persist cached files
  to their final S3 destinations.
  """
  @spec persist_cached_files([String.t()]) :: :ok
  def persist_cached_files(cache_keys) when is_list(cache_keys) do
    cache_keys
    |> Enum.each(fn cache_key ->
      # For temp cache keys, we need to get the S3 destination from the cached file
      s3_destination = resolve_s3_destination(cache_key)

      case TempCache.persist_to_s3(cache_key, s3_destination, "STANDARD") do
        :ok ->
          Logger.info("CacheArgs: Uploaded #{cache_key} to #{s3_destination}")

        {:error, :not_found} ->
          # File wasn't cached, that's fine (may have been uploaded directly)
          Logger.debug("CacheArgs: Cache key #{cache_key} not found, skipping")

        {:error, reason} ->
          Logger.error("CacheArgs: Failed to persist #{cache_key}: #{inspect(reason)}")
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
    case Videos.get_source_video(source_video_id) do
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

  defp s3_path_key?(key) do
    key_str = to_string(key)
    String.ends_with?(key_str, "_path") or String.ends_with?(key_str, "_video_path")
  end

  defp get_local_path_key(key) do
    key_str = to_string(key)
    base = String.replace_suffix(key_str, "_path", "")
    local_path_key = "#{base}_local_path"

    # Use safe atom conversion for known path keys
    case local_path_key do
      "source_video_local_path" -> :source_video_local_path
      "proxy_video_local_path" -> :proxy_video_local_path
      "master_video_local_path" -> :master_video_local_path
      "keyframe_video_local_path" -> :keyframe_video_local_path
      # Keep unknown keys as strings to avoid atom table pollution
      _ -> local_path_key
    end
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
  defp find_local_path_in_results(_results, []), do: {:error, :not_found}

  defp find_local_path_in_results(results, [pattern | remaining]) do
    case check_pattern_for_local_path(results, pattern) do
      {:ok, local_path} -> {:ok, local_path}
      :not_found -> find_local_path_in_results(results, remaining)
    end
  end

  defp check_pattern_for_local_path(results, pattern) do
    case Map.get(results, pattern) do
      local_path when is_binary(local_path) and local_path != "" ->
        if File.exists?(local_path), do: {:ok, local_path}, else: :not_found

      _ ->
        :not_found
    end
  end
end
