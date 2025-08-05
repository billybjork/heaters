defmodule Heaters.Storage.PipelineCache.PersistCache.Worker do
  @moduledoc """
  Worker for persisting cached temporary files to S3 storage.

  This worker handles the critical "scene detection complete → cached files persisted"
  stage of the video processing pipeline. It ensures that all temporary cached files
  created during the download and preprocessing stages are persisted to their final
  S3 destinations.

  ## Workflow

  1. Check if source video needs cache persistence
  2. Identify all cached files that should be persisted to S3
  3. Persist cached files to their final S3 destinations
  4. Clean up temporary cache entries
  5. Mark persistence as complete

  ## State Management

  - **Input**: Source videos with scene detection complete but cache not persisted
  - **Output**: Source videos with all files properly stored in S3
  - **Error Handling**: Graceful fallback - files may already be in S3 from traditional flow
  - **Idempotency**: Skip if already persisted or no cached files found

  ## Architecture

  - **Cache Management**: Uses TempCache and CacheArgs infrastructure
  - **State Management**: Elixir state transitions and database operations
  - **Storage**: Persists temporary files to permanent S3 storage
  """

  use Heaters.Pipeline.WorkerBehavior,
    queue: :media_processing,
    unique: [period: 900, fields: [:args]]

  alias Heaters.Repo
  alias Heaters.Media.Video, as: SourceVideo
  alias Heaters.Media.Videos
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Storage.PipelineCache.CacheArgs
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
    # Collect temp cache keys that might have cached files
    # The PreprocessWorker caches files with keys like "temp_#{id}_proxy" and "temp_#{id}_master"
    # The DownloadWorker caches files with S3 keys directly
    temp_cache_keys = collect_temp_cache_keys(source_video)
    s3_keys = collect_s3_keys(source_video)

    all_keys = temp_cache_keys ++ s3_keys

    if length(all_keys) > 0 do
      Logger.info(
        "PersistCacheWorker: Persisting #{length(all_keys)} potential cached files for video #{source_video.id}"
      )

      # Use CacheArgs to persist all cached files
      CacheArgs.persist_cached_files(all_keys)

      # Mark persistence as complete
      mark_persist_complete(source_video)
    else
      Logger.info("PersistCacheWorker: No files to persist for video #{source_video.id}")

      # Still mark as complete to avoid repeated processing
      mark_persist_complete(source_video)
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
end
