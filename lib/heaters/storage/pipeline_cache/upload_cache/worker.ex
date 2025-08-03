defmodule Heaters.Storage.PipelineCache.UploadCache.Worker do
  @moduledoc """
  Worker for uploading cached temporary files to S3 storage.

  This worker handles the critical "scene detection complete → cached files uploaded"
  stage of the video processing pipeline. It ensures that all temporary cached files
  created during the download and preprocessing stages are uploaded to their final
  S3 destinations.

  ## Workflow

  1. Check if source video needs cache upload
  2. Identify all cached files that should be uploaded to S3
  3. Upload cached files to their final S3 destinations
  4. Clean up temporary cache entries
  5. Mark upload as complete

  ## State Management

  - **Input**: Source videos with scene detection complete but cache not uploaded
  - **Output**: Source videos with all files properly stored in S3
  - **Error Handling**: Graceful fallback - files may already be in S3 from traditional flow
  - **Idempotency**: Skip if already uploaded or no cached files found

  ## Architecture

  - **Cache Management**: Uses TempCache and CacheArgs infrastructure
  - **State Management**: Elixir state transitions and database operations
  - **Storage**: Uploads temporary files to permanent S3 storage
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
    handle_finalization_work(args)
  end

  defp handle_finalization_work(%{"source_video_id" => source_video_id}) do
    Logger.info(
      "UploadCacheWorker: Starting cache upload for source_video_id: #{source_video_id}"
    )

    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      handle_upload(source_video)
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Source video", source_video_id)
    end
  end

  defp handle_upload(%SourceVideo{} = source_video) do
    # Check if upload is needed
    case needs_upload?(source_video) do
      true ->
        Logger.info("UploadCacheWorker: Starting upload for video #{source_video.id}")
        run_upload_task(source_video)

      false ->
        Logger.info("UploadCacheWorker: Video #{source_video.id} doesn't need upload, skipping")

        :ok
    end
  end

  defp needs_upload?(source_video) do
    # Video needs upload if:
    # 1. Scene detection is complete (has virtual clips or needs_splicing = false)
    # 2. Not already marked as uploaded
    # 3. Has potential cached files

    scene_detection_complete =
      source_video.needs_splicing == false or virtual_clips_exist?(source_video.id)

    not_already_uploaded =
      is_nil(source_video.cache_finalized_at)

    has_potential_cached_files =
      not is_nil(source_video.filepath) or
        not is_nil(source_video.proxy_filepath) or
        not is_nil(source_video.master_filepath)

    scene_detection_complete and not_already_uploaded and has_potential_cached_files
  end

  defp virtual_clips_exist?(source_video_id) do
    import Ecto.Query

    query =
      from(c in Heaters.Media.Clip,
        where: c.source_video_id == ^source_video_id and c.is_virtual == true,
        select: count("*")
      )

    Repo.one(query) > 0
  end

  defp run_upload_task(source_video) do
    # Collect temp cache keys that might have cached files
    # The PreprocessWorker caches files with keys like "temp_#{id}_proxy" and "temp_#{id}_master"
    # The DownloadWorker caches files with S3 keys directly
    temp_cache_keys = collect_temp_cache_keys(source_video)
    s3_keys = collect_s3_keys(source_video)

    all_keys = temp_cache_keys ++ s3_keys

    if length(all_keys) > 0 do
      Logger.info(
        "UploadCacheWorker: Uploading #{length(all_keys)} potential cached files for video #{source_video.id}"
      )

      # Use CacheArgs to upload all cached files
      CacheArgs.finalize_cached_files(all_keys)

      # Mark upload as complete
      mark_upload_complete(source_video)
    else
      Logger.info("UploadCacheWorker: No files to upload for video #{source_video.id}")

      # Still mark as complete to avoid repeated processing
      mark_upload_complete(source_video)
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

  defp mark_upload_complete(source_video) do
    case Videos.update_cache_finalized_at(source_video) do
      {:ok, _updated_video} ->
        Logger.info(
          "UploadCacheWorker: Successfully completed cache upload for video #{source_video.id}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "UploadCacheWorker: Failed to mark upload complete for video #{source_video.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
