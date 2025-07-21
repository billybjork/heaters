defmodule Heaters.Videos.Operations.Preprocessing.Worker do
  @moduledoc """
  Worker for preprocessing source videos into gold master and review proxy files.

  This worker handles the "downloaded → preprocessed" stage of the video processing pipeline.
  It creates two video files from the source video:
  1. Gold master (lossless MKV + FFV1) for final export
  2. Review proxy (all-I-frame H.264) for efficient seeking in the review UI

  ## Workflow

  1. Transition source video to "preprocessing" state
  2. Run Python preprocessing task to create gold master and proxy
  3. Extract keyframe offsets for efficient WebCodecs seeking
  4. Upload both files to S3 (cold storage for master, hot for proxy)
  5. Update source video with file paths and keyframe data

  ## State Management

  - **Input**: Source videos in "downloaded" state without proxy_filepath
  - **Output**: Source videos with proxy_filepath, gold_master_filepath, and keyframe_offsets
  - **Error Handling**: Marks source video as "preprocessing_failed" on errors
  - **Idempotency**: Skip if proxy_filepath IS NOT NULL (preprocessing already complete)

  ## Architecture

  - **Preprocessing**: Python task via PyRunner port
  - **State Management**: Elixir state transitions and database operations
  - **Storage**: S3 for both gold master and proxy files
  """

  use Heaters.Infrastructure.Orchestration.WorkerBehavior,
    queue: :media_processing,
    unique: [period: 900, fields: [:args]]

  alias Heaters.Videos.{SourceVideo, Queries}
  alias Heaters.Videos.Operations.Preprocessing.StateManager
  alias Heaters.Infrastructure.Orchestration.WorkerBehavior
  alias Heaters.Infrastructure.PyRunner
  require Logger

  @impl WorkerBehavior
  def handle_work(args) do
    handle_preprocessing_work(args)
  end

  defp handle_preprocessing_work(%{"source_video_id" => source_video_id}) do
    Logger.info("PreprocessingWorker: Starting preprocessing for source_video_id: #{source_video_id}")

    with {:ok, source_video} <- Queries.get_source_video(source_video_id) do
      handle_preprocessing(source_video)
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Source video", source_video_id)
    end
  end

  defp handle_preprocessing(%SourceVideo{} = source_video) do
    # IDEMPOTENCY: Skip if proxy_filepath IS NOT NULL (preprocessing already complete)
    case source_video.proxy_filepath do
      nil ->
        Logger.info("PreprocessingWorker: Starting preprocessing for video #{source_video.id}")
        run_preprocessing_task(source_video)

      _proxy_path ->
        Logger.info("PreprocessingWorker: Video #{source_video.id} already preprocessed, skipping")
        :ok
    end
  end

  defp run_preprocessing_task(source_video) do
    Logger.info("PreprocessingWorker: Running Python preprocessing for source_video_id: #{source_video.id}")

    # Transition to preprocessing state
    case StateManager.start_preprocessing(source_video.id) do
      {:ok, updated_video} ->
        execute_preprocessing(updated_video)

      {:error, reason} ->
        Logger.error("PreprocessingWorker: Failed to start preprocessing: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp execute_preprocessing(source_video) do
    preprocessing_args = %{
      source_video_id: source_video.id,
      source_video_path: source_video.filepath,
      video_title: source_video.title
    }

    Logger.info("PreprocessingWorker: Running Python preprocessing with args: #{inspect(preprocessing_args)}")

    case PyRunner.run("preprocessing", preprocessing_args, timeout: :timer.minutes(30)) do
      {:ok, %{"status" => "success"} = result} ->
        Logger.info("PreprocessingWorker: Python preprocessing completed successfully")
        process_preprocessing_results(source_video, result)

      {:ok, %{"status" => "error", "error" => error_msg}} ->
        Logger.error("PreprocessingWorker: Python preprocessing failed: #{error_msg}")
        mark_preprocessing_failed(source_video, error_msg)

      {:error, reason} ->
        Logger.error("PreprocessingWorker: PyRunner failed: #{inspect(reason)}")
        mark_preprocessing_failed(source_video, "PyRunner failed: #{inspect(reason)}")
    end
  end

  defp process_preprocessing_results(source_video, results) do
    # Extract results from Python task
    gold_master_path = Map.get(results, "gold_master_path")
    proxy_path = Map.get(results, "proxy_path")
    keyframe_offsets = Map.get(results, "keyframe_offsets", [])
    metadata = Map.get(results, "metadata", %{})

    update_attrs = %{
      gold_master_filepath: gold_master_path,
      proxy_filepath: proxy_path,
      keyframe_offsets: keyframe_offsets,
      ingest_state: "preprocessed"
    }
    |> maybe_put(:duration_seconds, metadata["duration_seconds"])
    |> maybe_put(:fps, metadata["fps"])
    |> maybe_put(:width, metadata["width"])
    |> maybe_put(:height, metadata["height"])

    case StateManager.complete_preprocessing(source_video.id, update_attrs) do
      {:ok, _final_video} ->
        Logger.info("PreprocessingWorker: Successfully completed preprocessing for video #{source_video.id}")
        :ok

      {:error, reason} ->
        Logger.error("PreprocessingWorker: Failed to update video state: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp mark_preprocessing_failed(source_video, reason) do
    case StateManager.mark_preprocessing_failed(source_video.id, reason) do
      {:ok, _} ->
        {:error, reason}

      {:error, db_error} ->
        Logger.error("PreprocessingWorker: Failed to mark video as failed: #{inspect(db_error)}")
        {:error, reason}
    end
  end

  # Helper function to conditionally put values in a map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
