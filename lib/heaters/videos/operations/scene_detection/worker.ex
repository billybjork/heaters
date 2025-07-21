defmodule Heaters.Videos.Operations.SceneDetection.Worker do
  @moduledoc """
  Worker for creating virtual clips from preprocessed source videos using scene detection.

  This worker handles the "preprocessed → virtual clips created" stage of the video processing pipeline.
  It runs scene detection on the review proxy and creates virtual clip records with cut points,
  but does NOT create physical clip files.

  ## Workflow

  1. Transition source video processing state
  2. Run Python scene detection on the review proxy file
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
  - **Physical clips**: Created later during export from gold master
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
  alias Heaters.Videos.Operations.SceneDetection.StateManager
  alias Heaters.Clips.Operations.VirtualClips
  alias Heaters.Infrastructure.Orchestration.WorkerBehavior
  alias Heaters.Infrastructure.PyRunner
  require Logger

  @impl WorkerBehavior
  def handle_work(args) do
    handle_scene_detection_work(args)
  end

  defp handle_scene_detection_work(%{"source_video_id" => source_video_id}) do
    Logger.info("SceneDetectionWorker: Starting scene detection for source_video_id: #{source_video_id}")

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
        Logger.info("SceneDetectionWorker: Video #{source_video.id} scene detection already complete, skipping")
        :ok

      :needs_processing ->
        Logger.info("SceneDetectionWorker: Starting scene detection for video #{source_video.id}")
        run_scene_detection_task(source_video)

      {:error, reason} ->
        Logger.error("SceneDetectionWorker: Cannot process video #{source_video.id}: #{reason}")
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
        Logger.info("SceneDetectionWorker: Virtual clips already exist for video #{source_video.id}, marking complete")
        # Update needs_splicing to false if virtual clips exist but flag not set
        StateManager.mark_scene_detection_complete(source_video.id)
        :complete

      true ->
        :needs_processing
    end
  end

  defp virtual_clips_exist?(source_video_id) do
    import Ecto.Query

    query = from(c in Heaters.Clips.Clip,
      where: c.source_video_id == ^source_video_id and c.is_virtual == true,
      select: count("*")
    )

    Heaters.Repo.one(query) > 0
  end

  defp run_scene_detection_task(source_video) do
    Logger.info("SceneDetectionWorker: Running Python scene detection for source_video_id: #{source_video.id}")

    # Transition to scene_detection state
    case StateManager.start_scene_detection(source_video.id) do
      {:ok, updated_video} ->
        execute_scene_detection(updated_video)

      {:error, reason} ->
        Logger.error("SceneDetectionWorker: Failed to start scene detection: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp execute_scene_detection(source_video) do
    # Use the proxy file for scene detection (faster than source)
    scene_detection_args = %{
      source_video_id: source_video.id,
      proxy_video_path: source_video.proxy_filepath,
      threshold: 0.6,
      method: "correl",
      min_duration_seconds: 1.0
    }

    Logger.info("SceneDetectionWorker: Running Python scene detection with args: #{inspect(scene_detection_args)}")

    case PyRunner.run("detect_scenes", scene_detection_args, timeout: :timer.minutes(15)) do
      {:ok, %{"status" => "success"} = result} ->
        Logger.info("SceneDetectionWorker: Python scene detection completed successfully")
        process_scene_detection_results(source_video, result)

      {:ok, %{"status" => "error", "error" => error_msg}} ->
        Logger.error("SceneDetectionWorker: Python scene detection failed: #{error_msg}")
        mark_scene_detection_failed(source_video, error_msg)

      {:error, reason} ->
        Logger.error("SceneDetectionWorker: PyRunner failed: #{inspect(reason)}")
        mark_scene_detection_failed(source_video, "PyRunner failed: #{inspect(reason)}")
    end
  end

  defp process_scene_detection_results(source_video, results) do
    # Extract cut points from Python scene detection
    cut_points = Map.get(results, "cut_points", [])
    metadata = Map.get(results, "metadata", %{})

    case VirtualClips.create_virtual_clips_from_cut_points(source_video.id, cut_points, metadata) do
      {:ok, created_clips} ->
        Logger.info("SceneDetectionWorker: Successfully created #{length(created_clips)} virtual clips")

        case StateManager.complete_scene_detection(source_video.id) do
          {:ok, _final_video} ->
            Logger.info("SceneDetectionWorker: Successfully completed scene detection for video #{source_video.id}")
            :ok

          {:error, reason} ->
            Logger.error("SceneDetectionWorker: Failed to update video state: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("SceneDetectionWorker: Failed to create virtual clips: #{inspect(reason)}")
        mark_scene_detection_failed(source_video, reason)
    end
  end

  defp mark_scene_detection_failed(source_video, reason) do
    case StateManager.mark_scene_detection_failed(source_video.id, reason) do
      {:ok, _} ->
        {:error, reason}

      {:error, db_error} ->
        Logger.error("SceneDetectionWorker: Failed to mark video as failed: #{inspect(db_error)}")
        {:error, reason}
    end
  end
end
