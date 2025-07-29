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

        # Cache files that end with "_path"
        if String.ends_with?(to_string(key), "_path") and is_binary(value) do
          # Extract filename for local caching
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

            {:error, _} ->
              acc
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
  def finalize_cached_files(s3_keys) when is_list(s3_keys) do
    s3_keys
    |> Enum.each(fn s3_key ->
      case TempCache.finalize_to_s3(s3_key) do
        :ok ->
          Logger.debug("CacheArgs: Finalized #{s3_key}")

        {:error, :not_found} ->
          # File wasn't cached, that's fine
          :ok

        {:error, reason} ->
          Logger.error("CacheArgs: Failed to finalize #{s3_key}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  ## Private Functions

  defp is_s3_path_key?(key) do
    key_str = to_string(key)
    String.ends_with?(key_str, "_path") or String.ends_with?(key_str, "_video_path")
  end

  defp get_local_path_key(key) do
    key_str = to_string(key)
    base = String.replace_suffix(key_str, "_path", "")
    String.to_atom("#{base}_local_path")
  end

  defp extract_temp_file_path(_results, _key) do
    # This would need to be implemented based on how Python tasks
    # provide local file paths. For now, we'll assume they don't
    # provide this information directly.
    {:error, :not_available}
  end
end
