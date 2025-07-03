defmodule Heaters.Workers.Videos.SpliceWorker do
  @moduledoc """
  Worker for processing source videos into clips using Python-based scene detection.

  This worker handles the "downloaded → spliced" stage of the video processing pipeline.
  It uses Python OpenCV for scene detection via PyRunner port communication, then
  processes clips using Elixir FFmpeg operations.

  ## Workflow

  1. Transition source video to "splicing" state
  2. Run Python scene detection and Elixir clip extraction
  3. Create clip records in database
  4. Transition source video to "spliced" state
  5. Enqueue sprite workers for each created clip

  ## State Management

  - **Input**: Source videos in "downloaded" state
  - **Output**: Clips in "spliced" state, source video in "spliced" state
  - **Error Handling**: Marks source video as "splicing_failed" on errors
  - **Idempotency**: S3-based scene detection caching and clip existence checking prevents reprocessing

  ## Architecture

  - **Scene Detection**: Python OpenCV via PyRunner port
  - **Clip Extraction**: Elixir FFmpeg operations
  - **State Management**: Elixir state transitions and database operations
  - **Storage**: S3 for videos/clips and scene detection caching
  """

  use Heaters.Workers.GenericWorker, queue: :media_processing, unique: [period: 300, fields: [:args]]

  alias Heaters.Videos.{SourceVideo, Operations}
  alias Heaters.Videos.Operations.Splice.StateManager
  alias Heaters.Clips.Operations.SpliceClips
  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Workers.Clips.SpriteWorker
  require Logger

  @splicing_complete_states ["spliced", "splicing_failed"]

  @impl Heaters.Workers.GenericWorker
  def handle(%{"source_video_id" => source_video_id}) do
    Logger.info("SpliceWorker: Starting splice for source_video_id: #{source_video_id}")

    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      handle_splicing(source_video)
    else
      {:error, :not_found} ->
        Logger.warning("SpliceWorker: Source video #{source_video_id} not found")
        :ok
    end
  end

  defp handle_splicing(%SourceVideo{ingest_state: state} = source_video)
       when state in @splicing_complete_states do
    Logger.info(
      "SpliceWorker: Source video #{source_video.id} already in state '#{state}', skipping"
    )

    :ok
  end

  defp handle_splicing(%SourceVideo{ingest_state: "splicing"} = source_video) do
    Logger.info(
      "SpliceWorker: Source video #{source_video.id} already in 'splicing' state, proceeding with splice task"
    )

    run_splice_task(source_video)
  end

  defp handle_splicing(source_video) do
    # Use new StateManager for splice-specific state transitions
    case StateManager.start_splicing(source_video.id) do
      {:ok, updated_video} ->
        run_splice_task(updated_video)

      {:error, reason} ->
        Logger.error("SpliceWorker: Failed to transition to splicing state: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_splice_task(source_video) do
    Logger.info(
      "SpliceWorker: Running Python-based splice for source_video_id: #{source_video.id}"
    )

    splice_opts = [
      threshold: 0.3,
      method: :correl,
      min_duration_seconds: 1.0
    ]

    case Operations.Splice.run_splice(source_video, splice_opts) do
      %{status: "success", clips_data: clips_data} when is_list(clips_data) ->
        Logger.info(
          "SpliceWorker: Successfully processed #{length(clips_data)} clips with Python-based splice"
        )

        process_splice_results(source_video, clips_data)

      %{status: "error", metadata: %{error: error_message}} ->
        Logger.error("SpliceWorker: Python splice failed: #{error_message}")
        mark_splicing_failed(source_video, error_message)

      unexpected_result ->
        error_message = "Python splice returned unexpected result: #{inspect(unexpected_result)}"
        Logger.error("SpliceWorker: #{error_message}")
        mark_splicing_failed(source_video, error_message)
    end
  end

  defp process_splice_results(source_video, clips_data) do
    # Use new SpliceClips for clip creation and validation
    case SpliceClips.validate_clips_data(clips_data) do
      :ok ->
        # Create clips and update source video state
        case SpliceClips.create_clips_from_splice(source_video.id, clips_data) do
          {:ok, clips} ->
            case StateManager.complete_splicing(source_video.id) do
              {:ok, _final_video} ->
                # Store clips for enqueue_next/1 (maintains existing pattern)
                Process.put(:clips, clips)
                :ok

              {:error, reason} ->
                Logger.error("SpliceWorker: Failed to mark splicing complete: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("SpliceWorker: Failed to create clips: #{inspect(reason)}")
            mark_splicing_failed(source_video, reason)
        end

      {:error, validation_error} ->
        Logger.error("SpliceWorker: Invalid clips data: #{validation_error}")
        mark_splicing_failed(source_video, validation_error)
    end
  end

  defp mark_splicing_failed(source_video, reason) do
    case StateManager.mark_splicing_failed(source_video, reason) do
      {:ok, _} ->
        {:error, reason}

      {:error, db_error} ->
        Logger.error("SpliceWorker: Failed to mark video as failed: #{inspect(db_error)}")
        {:error, reason}
    end
  end

  @impl Heaters.Workers.GenericWorker
  def enqueue_next(_args) do
    case Process.get(:clips) do
      clips when is_list(clips) ->
        # Enqueue sprite workers for all created clips
        jobs =
          clips
          |> Enum.map(fn clip ->
            SpriteWorker.new(%{clip_id: clip.id})
          end)

        try do
          case Oban.insert_all(jobs) do
            inserted_jobs when is_list(inserted_jobs) and length(inserted_jobs) > 0 ->
              Logger.info("SpliceWorker: Enqueued #{length(inserted_jobs)} sprite workers")
              :ok

            [] ->
              Logger.error("SpliceWorker: Failed to enqueue sprite workers - no jobs inserted")
              {:error, "No sprite jobs were enqueued"}

            %Ecto.Multi{} = multi ->
              Logger.error(
                "SpliceWorker: Oban.insert_all returned Multi instead of jobs: #{inspect(multi)}"
              )

              {:error, "Unexpected Multi result from Oban.insert_all"}
          end
        rescue
          error ->
            error_message = "Failed to enqueue sprite workers: #{Exception.message(error)}"
            Logger.error("SpliceWorker: #{error_message}")
            {:error, error_message}
        end

      _ ->
        {:error, "No clips found to enqueue sprite workers"}
    end
  end
end
