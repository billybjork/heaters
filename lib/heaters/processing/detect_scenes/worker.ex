defmodule Heaters.Processing.DetectScenes.Worker do
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
  - **Output**: Virtual clips in :pending_review state, source video with needs_splicing = false
  - **Error Handling**: Marks source video as :detecting_scenes_failed on errors
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

  use Heaters.Pipeline.WorkerBehavior,
    queue: :media_processing,
    unique: [period: 900, fields: [:args]]

  alias Heaters.Repo
  alias Heaters.Media.{Video, Videos}
  alias Heaters.Processing.DetectScenes.StateManager
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Pipeline.Config, as: PipelineConfig
  alias Heaters.Processing.Py.Runner, as: PyRunner
  require Logger

  # Suppress dialyzer warnings for PyRunner calls when environment is not configured.
  #
  # JUSTIFICATION: PyRunner requires DEV_DATABASE_URL and DEV_S3_BUCKET_NAME environment
  # variables. When not set, PyRunner always fails, making success patterns unreachable.
  # In configured environments, these functions will succeed normally.
  @dialyzer {:nowarn_function, [run_python_scene_detection: 2]}

  @impl WorkerBehavior
  def handle_work(args) do
    handle_scene_detection_work(args)
  end

  defp handle_scene_detection_work(%{"source_video_id" => source_video_id}) do
    Logger.info(
      "DetectScenesWorker: Starting scene detection for source_video_id: #{source_video_id}"
    )

    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      handle_scene_detection(source_video)
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Source video", source_video_id)
    end
  end

  defp handle_scene_detection(%Video{} = source_video) do
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

    # Check if clips exist (clips without filepath are virtual in the new architecture)
    query =
      from(c in Heaters.Media.Clip,
        where: c.source_video_id == ^source_video_id and is_nil(c.clip_filepath),
        select: count("*")
      )

    Repo.one(query) > 0
  end

  defp run_scene_detection_task(source_video) do
    Logger.info(
      "DetectScenesWorker: Running Python scene detection for source_video_id: #{source_video.id}"
    )

    # Transition to detecting_scenes state
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

    proxy_path_result =
      case Heaters.Storage.PipelineCache.TempCache.get(temp_cache_key) do
        {:ok, cached_path} ->
          Logger.info("DetectScenesWorker: Using temp cached proxy: #{cached_path}")
          {:ok, cached_path, :cache_hit}

        {:error, _} ->
          # Fallback to S3 download if not in temp cache
          Heaters.Storage.PipelineCache.TempCache.get_or_download(
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

    case PyRunner.run_python_task(:detect_scenes, scene_detection_args,
           timeout: :timer.minutes(15)
         ) do
      {:ok, result} ->
        Logger.info("DetectScenesWorker: Python scene detection completed successfully")

        # Extract segments from Python scene detection and convert to cut points
        segments = Map.get(result, "cut_points", [])
        metadata = Map.get(result, "metadata", %{})
        
        # Convert segments to actual cut points (boundaries between segments)
        cut_points = convert_segments_to_cut_points(segments)

        case Heaters.Media.Cuts.Operations.create_initial_cuts(
               source_video.id,
               cut_points,
               metadata
             ) do
          {:ok, {_cuts, created_clips}} ->
            Logger.info(
              "DetectScenesWorker: Successfully created #{length(created_clips)} virtual clips"
            )

            case StateManager.complete_scene_detection(source_video.id) do
              {:ok, final_video} ->
                Logger.info(
                  "DetectScenesWorker: Successfully completed scene detection for video #{source_video.id}"
                )

                # Chain directly to next stage using centralized pipeline configuration
                :ok = PipelineConfig.maybe_chain_next_job(__MODULE__, final_video)
                Logger.info("DetectScenesWorker: Successfully chained to next pipeline stage")
                :ok

              {:error, reason} ->
                Logger.error(
                  "DetectScenesWorker: Failed to update video state: #{inspect(reason)}"
                )

                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("DetectScenesWorker: Failed to create virtual clips: #{inspect(reason)}")
            mark_scene_detection_failed(source_video, reason)
        end

      {:error, reason} ->
        Logger.error("DetectScenesWorker: PyRunner failed: #{reason}")
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

  # Convert scene detection segments to cut points.
  # 
  # Python scene detection returns segments with start/end frames, but the Elixir
  # cut system expects cut points (boundaries between segments).
  defp convert_segments_to_cut_points(segments) when is_list(segments) do
    segments
    |> Enum.sort_by(& &1["start_frame"])
    |> Enum.flat_map(fn segment ->
      cut_points = []
      
      # Add cut point at the start of this segment (if not starting at frame 0)
      cut_points = if segment["start_frame"] > 0 do
        start_cut = %{
          "frame_number" => segment["start_frame"],
          "time_seconds" => segment["start_time_seconds"]
        }
        [start_cut | cut_points]
      else
        cut_points
      end
      
      # Add cut point at the end of this segment
      end_cut = %{
        "frame_number" => segment["end_frame"],
        "time_seconds" => segment["end_time_seconds"]
      }
      [end_cut | cut_points]
    end)
    |> Enum.uniq_by(& &1["frame_number"])
    |> Enum.sort_by(& &1["frame_number"])
    # Remove the final cut point (end of video)
    |> Enum.reverse()
    |> tl()
    |> Enum.reverse()
  end

  defp convert_segments_to_cut_points(_), do: []
end
