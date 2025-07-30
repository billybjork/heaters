defmodule Heaters.Videos.DetectScenes.Worker do
  @moduledoc """
  Worker for creating virtual clips from preprocessed source videos using scene detection.

  This worker handles the "preprocessed → virtual clips created" stage of the video processing pipeline.
  It runs scene detection on the proxy and creates virtual clip records with cut points,
  but does NOT create physical clip files.

  ## Workflow

  1. Transition source video processing state
  2. Run Python scene detection on the proxy file
  3. Create virtual clip records in database with cut points
  4. Set needs_splicing = false to mark scene detection complete
  5. Virtual clips enter review workflow

  ## State Management

  - **Input**: Source videos with proxy_filepath and needs_splicing = true
  - **Output**: Virtual clips in "pending_review" state, source video with needs_splicing = false
  - **Error Handling**: Marks source video as "scene_detection_failed" on errors
  - **Idempotency**: Skip if needs_splicing = false OR virtual clips already exist

  ## Virtual Clips vs Physical Clips

  - **Virtual clips**: Only cut points in database, no file encoding
  - **Physical clips**: Created later during export from master
  - **Review workflow**: Same for both, but virtual clips are much faster to merge/split

  ## Architecture

  - **Scene Detection**: Python OpenCV via PyRunner port (same as current)
  - **State Management**: Elixir state transitions and database operations
  - **Storage**: Database only for virtual clips, no S3 file operations
  """

  use Heaters.Infrastructure.Orchestration.WorkerBehavior,
    queue: :media_processing,
    unique: [period: 900, fields: [:args]]

  alias Heaters.Videos.{SourceVideo, Queries}
  alias Heaters.Videos.DetectScenes.StateManager
  alias Heaters.Clips.VirtualClips
  alias Heaters.Infrastructure.Orchestration.{WorkerBehavior, PipelineConfig}
  alias Heaters.Infrastructure.{PyRunner, TempCache}
  require Logger

  @impl WorkerBehavior
  def handle_work(args) do
    handle_scene_detection_work(args)
  end

  defp handle_scene_detection_work(%{"source_video_id" => source_video_id}) do
    Logger.info(
      "DetectScenesWorker: Starting scene detection for source_video_id: #{source_video_id}"
    )

    with {:ok, source_video} <- Queries.get_source_video(source_video_id) do
      handle_scene_detection(source_video)
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Source video", source_video_id)
    end
  end

  defp handle_scene_detection(%SourceVideo{} = source_video) do
    # IDEMPOTENCY: Skip if needs_splicing = false OR virtual clips already exist
    case check_scene_detection_complete(source_video) do
      :complete ->
        Logger.info(
          "DetectScenesWorker: Video #{source_video.id} scene detection already complete, skipping"
        )

        :ok

      :needs_processing ->
        Logger.info("DetectScenesWorker: Starting scene detection for video #{source_video.id}")
        run_scene_detection_task(source_video)

      {:error, reason} ->
        Logger.error("DetectScenesWorker: Cannot process video #{source_video.id}: #{reason}")
        {:error, reason}
    end
  end

  defp check_scene_detection_complete(source_video) do
    cond do
      # Missing proxy file - cannot proceed
      is_nil(source_video.proxy_filepath) ->
        {:error, "No proxy file available - preprocessing not complete"}

      # Already marked as not needing splicing
      source_video.needs_splicing == false ->
        :complete

      # Check if virtual clips already exist
      virtual_clips_exist?(source_video.id) ->
        Logger.info(
          "DetectScenesWorker: Virtual clips already exist for video #{source_video.id}, marking complete"
        )

        # Update needs_splicing to false if virtual clips exist but flag not set
        StateManager.mark_scene_detection_complete(source_video.id)
        :complete

      true ->
        :needs_processing
    end
  end

  defp virtual_clips_exist?(source_video_id) do
    import Ecto.Query

    query =
      from(c in Heaters.Clips.Clip,
        where: c.source_video_id == ^source_video_id and c.is_virtual == true,
        select: count("*")
      )

    Heaters.Repo.one(query) > 0
  end

  defp run_scene_detection_task(source_video) do
    Logger.info(
      "DetectScenesWorker: Running Python scene detection for source_video_id: #{source_video.id}"
    )

    # Transition to scene_detection state
    case StateManager.start_scene_detection(source_video.id) do
      {:ok, updated_video} ->
        execute_scene_detection(updated_video)

      {:error, reason} ->
        Logger.error("DetectScenesWorker: Failed to start scene detection: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp execute_scene_detection(source_video) do
    # Try to get proxy file from temp cache first (using temp cache key), then fallback to S3
    temp_cache_key = "temp_#{source_video.id}_proxy"
    
    proxy_path_result = case TempCache.get(temp_cache_key) do
      {:ok, cached_path} ->
        Logger.info("DetectScenesWorker: Using temp cached proxy: #{cached_path}")
        {:ok, cached_path, :cache_hit}
      
      {:error, _} ->
        # Fallback to S3 download if not in temp cache
        TempCache.get_or_download(
          source_video.proxy_filepath,
          operation_name: "DetectScenesWorker"
        )
    end

    case proxy_path_result do
      {:ok, local_proxy_path, cache_status} ->
        Logger.info("DetectScenesWorker: Using #{cache_status} proxy file: #{local_proxy_path}")

        # Use the local proxy file for scene detection (faster than S3)
        scene_detection_args = %{
          source_video_id: source_video.id,
          # Use local path instead of S3 path
          proxy_video_path: local_proxy_path,
          threshold: 0.6,
          method: "correl",
          min_duration_seconds: 1.0,
          # Reuse existing keyframe data
          keyframe_offsets: source_video.keyframe_offsets || []
        }

        run_python_scene_detection(source_video, scene_detection_args)

      {:error, reason} ->
        Logger.error("DetectScenesWorker: Failed to get proxy video: #{inspect(reason)}")
        {:error, "Failed to get proxy video: #{inspect(reason)}"}
    end
  end

  defp run_python_scene_detection(source_video, scene_detection_args) do
    Logger.info(
      "DetectScenesWorker: Running Python scene detection with args: #{inspect(Map.delete(scene_detection_args, :proxy_video_path))}"
    )

    case PyRunner.run("detect_scenes", scene_detection_args, timeout: :timer.minutes(15)) do
      {:ok, %{"status" => "success"} = result} ->
        Logger.info("DetectScenesWorker: Python scene detection completed successfully")
        process_scene_detection_results(source_video, result)

      {:ok, %{"status" => "error", "error" => error_msg}} ->
        Logger.error("DetectScenesWorker: Python scene detection failed: #{error_msg}")
        mark_scene_detection_failed(source_video, error_msg)

      {:error, reason} ->
        Logger.error("DetectScenesWorker: PyRunner failed: #{inspect(reason)}")
        mark_scene_detection_failed(source_video, "PyRunner failed: #{inspect(reason)}")
    end
  end

  defp process_scene_detection_results(source_video, results) do
    # Extract cut points from Python scene detection
    cut_points = Map.get(results, "cut_points", [])
    metadata = Map.get(results, "metadata", %{})

    case VirtualClips.create_virtual_clips_from_cut_points(source_video.id, cut_points, metadata) do
      {:ok, created_clips} ->
        Logger.info(
          "DetectScenesWorker: Successfully created #{length(created_clips)} virtual clips"
        )

        case StateManager.complete_scene_detection(source_video.id) do
          {:ok, final_video} ->
            Logger.info(
              "DetectScenesWorker: Successfully completed scene detection for video #{source_video.id}"
            )

            # Chain directly to next stage using centralized pipeline configuration
            case PipelineConfig.maybe_chain_next_job(__MODULE__, final_video) do
              :ok ->
                Logger.info("DetectScenesWorker: Successfully chained to next pipeline stage")
                :ok
              
              {:error, reason} ->
                Logger.warning("DetectScenesWorker: Failed to chain to next stage: #{inspect(reason)}")
                # Fallback to dispatcher-based processing
                :ok
            end

          {:error, reason} ->
            Logger.error("DetectScenesWorker: Failed to update video state: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("DetectScenesWorker: Failed to create virtual clips: #{inspect(reason)}")
        mark_scene_detection_failed(source_video, reason)
    end
  end

  defp mark_scene_detection_failed(source_video, reason) do
    case StateManager.mark_scene_detection_failed(source_video.id, reason) do
      {:ok, _} ->
        {:error, reason}

      {:error, db_error} ->
        Logger.error("DetectScenesWorker: Failed to mark video as failed: #{inspect(db_error)}")
        {:error, reason}
    end
  end
end
