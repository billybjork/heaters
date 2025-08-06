defmodule Heaters.Storage.PipelineCache.PersistCache.Worker do
  @moduledoc """
  Worker for persisting cached temporary files to S3 storage.

  This worker handles the critical "scene detection complete → cached files persisted"
  stage of the video processing pipeline. It ensures that all temporary cached files
  created during the download and preprocessing stages are persisted to their final
  S3 destinations.

  ## Workflow

  1. Check if source video needs cache persistence
  2. **Mark persistence as started immediately** (prevents Dispatcher race conditions)
  3. Identify all cached files that should be persisted to S3
  4. Persist cached files to their final S3 destinations using proper title-based naming
  5. Update database with actual S3 file paths (proxy_filepath, master_filepath)
  6. Clean up temporary cache entries

  ## S3 Path Generation

  **CRITICAL**: S3 paths must be consistent between Python preprocessing and Elixir persistence.

  The title flow through the pipeline:
  1. **Download stage**: Updates source_video.title from extracted metadata
  2. **Preprocess stage**: Python uses title to generate S3 paths:
     `f"proxies/{sanitized_title}_{video_id}_proxy.mp4"`
  3. **Persist stage**: Elixir must use identical logic to resolve cache keys to S3 paths

  Both Python and Elixir use the same sanitization rules to ensure path consistency.

  ## State Management

  - **Input**: Source videos with scene detection complete but cache not persisted
  - **Output**: Source videos with all files properly stored in S3 and database updated
  - **Error Handling**: Graceful fallback - files may already be in S3 from traditional flow
  - **Idempotency**: Skip if already persisted or no cached files found

  ## Race Condition Prevention

  **CRITICAL**: `cache_persisted_at` is set IMMEDIATELY at the start of processing to prevent
  race conditions with the Dispatcher. This closes the timing window where:

  1. DetectScenes chains to PersistCache (immediate execution)
  2. PersistCache starts S3 uploads (takes 30+ seconds)
  3. Dispatcher runs every 30 seconds and sees `cache_persisted_at = NULL`
  4. Dispatcher creates duplicate PersistCache job → concurrent S3 uploads → file conflicts

  By marking persistence as started upfront, the Dispatcher will always see the video
  as "already being processed" and skip duplicate job creation.

  ## Architecture

  - **Cache Management**: Uses TempCache and CacheArgs infrastructure
  - **State Management**: Elixir state transitions and database operations
  - **Storage**: Persists temporary files to permanent S3 storage
  - **Database Updates**: Updates source_video record with actual S3 paths
  """

  use Heaters.Pipeline.WorkerBehavior,
    queue: :media_processing,
    unique: [period: 900, fields: [:args]]

  alias Heaters.Repo
  alias Heaters.Media.Video, as: SourceVideo
  alias Heaters.Media.Videos
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Storage.PipelineCache.TempCache
  require Logger

  @impl WorkerBehavior
  def handle_work(args) do
    handle_persist_work(args)
  end

  defp handle_persist_work(%{"source_video_id" => source_video_id}) do
    Logger.info(
      "PersistCacheWorker: Starting cache persistence for source_video_id: #{source_video_id}"
    )

    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      handle_persist(source_video)
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Source video", source_video_id)
    end
  end

  defp handle_persist(%SourceVideo{} = source_video) do
    # Check if persistence is needed
    case needs_persist?(source_video) do
      true ->
        Logger.info("PersistCacheWorker: Starting persistence for video #{source_video.id}")
        run_persist_task(source_video)

      false ->
        Logger.info(
          "PersistCacheWorker: Video #{source_video.id} doesn't need persistence, skipping"
        )

        :ok
    end
  end

  defp needs_persist?(source_video) do
    # Video needs persistence if:
    # 1. Scene detection is complete (has virtual clips or needs_splicing = false)
    # 2. Not already marked as persisted
    # 3. Has potential cached files

    scene_detection_complete =
      source_video.needs_splicing == false or virtual_clips_exist?(source_video.id)

    not_already_persisted =
      is_nil(source_video.cache_persisted_at)

    has_potential_cached_files =
      not is_nil(source_video.filepath) or
        not is_nil(source_video.proxy_filepath) or
        not is_nil(source_video.master_filepath)

    scene_detection_complete and not_already_persisted and has_potential_cached_files
  end

  defp virtual_clips_exist?(source_video_id) do
    import Ecto.Query

    query =
      from(c in Heaters.Media.Clip,
        where: c.source_video_id == ^source_video_id and is_nil(c.clip_filepath),
        select: count("*")
      )

    Repo.one(query) > 0
  end

  defp run_persist_task(source_video) do
    # Mark persistence as started immediately to prevent race conditions with Dispatcher
    # This closes the timing window where Dispatcher creates duplicate jobs while uploads are in progress
    case mark_persist_complete(source_video) do
      :ok ->
        Logger.info(
          "PersistCacheWorker: Marked persistence as started for video #{source_video.id}"
        )

        # Collect temp cache keys that might have cached files
        # The PreprocessWorker caches files with keys like "temp_#{id}_proxy" and "temp_#{id}_master"
        # The DownloadWorker caches files with S3 keys directly
        temp_cache_keys = collect_temp_cache_keys(source_video)
        s3_keys = collect_s3_keys(source_video)

        # Deduplicate keys by S3 destination to prevent racing uploads of the same file
        # Both temp cache keys and S3 keys might resolve to the same S3 destination
        all_keys = deduplicate_by_s3_destination(temp_cache_keys ++ s3_keys)

        if length(all_keys) > 0 do
          Logger.info(
            "PersistCacheWorker: Persisting #{length(all_keys)} potential cached files for video #{source_video.id}"
          )

          # Persist cached files and track successful uploads
          successful_uploads = persist_cached_files_with_tracking(all_keys)

          # Update database with successful S3 paths
          update_database_with_s3_paths(source_video, successful_uploads)

          Logger.info(
            "PersistCacheWorker: Successfully completed cache persistence for video #{source_video.id}"
          )
        else
          Logger.info("PersistCacheWorker: No files to persist for video #{source_video.id}")
        end

        :ok

      {:error, reason} ->
        Logger.error(
          "PersistCacheWorker: Failed to mark persistence as started for video #{source_video.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp collect_temp_cache_keys(source_video) do
    # These are the keys used by PreprocessWorker when caching temp files
    [
      "temp_#{source_video.id}_proxy",
      "temp_#{source_video.id}_master"
    ]
  end

  defp collect_s3_keys(source_video) do
    # These are the keys used by DownloadWorker when caching temp files
    [
      source_video.filepath,
      source_video.proxy_filepath,
      source_video.master_filepath
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp deduplicate_by_s3_destination(cache_keys) do
    # Group cache keys by their S3 destinations to prevent multiple uploads of the same file
    cache_keys
    |> Enum.group_by(&resolve_s3_destination/1)
    |> Enum.map(fn {_s3_destination, keys} ->
      # For each S3 destination, prefer temp cache keys over direct S3 keys
      # because temp cache keys have better error handling and progress tracking
      temp_keys = Enum.filter(keys, &String.starts_with?(&1, "temp_"))

      case temp_keys do
        # Use first temp cache key if available
        [temp_key | _] -> temp_key
        # Fall back to first S3 key if no temp keys
        [] -> List.first(keys)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp persist_cached_files_with_tracking(cache_keys) do
    # Track successful uploads with their S3 destinations
    cache_keys
    |> Enum.map(fn cache_key ->
      s3_destination = resolve_s3_destination(cache_key)

      case TempCache.persist_to_s3(cache_key, s3_destination, "STANDARD") do
        :ok ->
          Logger.info("CacheArgs: Uploaded #{cache_key} to #{s3_destination}")
          {:ok, cache_key, s3_destination}

        {:error, :not_found} ->
          Logger.debug("CacheArgs: Cache key #{cache_key} not found, skipping")
          {:not_found, cache_key, s3_destination}

        {:error, reason} ->
          Logger.error("CacheArgs: Failed to persist #{cache_key}: #{inspect(reason)}")
          {:error, cache_key, s3_destination, reason}
      end
    end)
    |> Enum.filter(fn
      {:ok, _cache_key, _s3_destination} -> true
      _ -> false
    end)
    |> Enum.map(fn {:ok, cache_key, s3_destination} -> {cache_key, s3_destination} end)
  end

  defp update_database_with_s3_paths(source_video, successful_uploads) do
    # Build update attributes from successful uploads
    attrs =
      successful_uploads
      |> Enum.reduce(%{}, fn {cache_key, s3_destination}, acc ->
        case cache_key do
          "temp_" <> rest ->
            case String.split(rest, "_") do
              [_id, "proxy"] -> Map.put(acc, :proxy_filepath, s3_destination)
              [_id, "master"] -> Map.put(acc, :master_filepath, s3_destination)
              _ -> acc
            end

          _ ->
            # For direct S3 keys, determine type from path
            cond do
              String.contains?(s3_destination, "/proxy") ->
                Map.put(acc, :proxy_filepath, s3_destination)

              String.contains?(s3_destination, "/master") ->
                Map.put(acc, :master_filepath, s3_destination)

              String.contains?(s3_destination, "originals") ->
                Map.put(acc, :filepath, s3_destination)

              true ->
                acc
            end
        end
      end)

    if map_size(attrs) > 0 do
      case Videos.update_source_video(source_video, attrs) do
        {:ok, updated_video} ->
          Logger.info(
            "PersistCacheWorker: Updated source_video #{source_video.id} with S3 paths: #{inspect(Map.keys(attrs))}"
          )

          {:ok, updated_video}

        {:error, reason} ->
          Logger.error(
            "PersistCacheWorker: Failed to update source_video #{source_video.id} with S3 paths: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      Logger.debug(
        "PersistCacheWorker: No S3 paths to update for source_video #{source_video.id}"
      )

      {:ok, source_video}
    end
  end

  defp mark_persist_complete(source_video) do
    case Videos.update_cache_persisted_at(source_video) do
      {:ok, _updated_video} ->
        Logger.info(
          "PersistCacheWorker: Successfully completed cache persistence for video #{source_video.id}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "PersistCacheWorker: Failed to mark persistence complete for video #{source_video.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Helper function to resolve S3 destination (extracted from CacheArgs)
  defp resolve_s3_destination(cache_key) do
    if String.starts_with?(cache_key, "temp_") do
      case parse_temp_cache_key(cache_key) do
        {:ok, source_video_id, file_type} ->
          get_s3_path_from_database(source_video_id, file_type)

        {:error, _} ->
          cache_key
      end
    else
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
          "proxy" ->
            source_video.proxy_filepath ||
              Heaters.Storage.S3.Paths.generate_proxy_path(source_video.title, source_video.id)

          "master" ->
            source_video.master_filepath ||
              Heaters.Storage.S3.Paths.generate_master_path(source_video.title, source_video.id)

          "source" ->
            source_video.filepath

          _ ->
            nil
        end

      {:error, _} ->
        # Cannot generate proper path without video record - this should not happen
        # in normal flow since we're processing an existing video
        Logger.warning(
          "PersistCacheWorker: Could not load source_video #{source_video_id} for S3 path generation"
        )

        nil
    end
  end

  # S3 path generation moved to Heaters.Storage.S3.Paths module
  # to eliminate coupling between Python and Elixir path generation logic
end
