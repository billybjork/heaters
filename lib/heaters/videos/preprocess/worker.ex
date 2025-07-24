defmodule Heaters.Videos.Preprocess.Worker do
  @moduledoc """
  Worker for preprocessing source videos into master and proxy files.

  This worker handles the "downloaded → preprocessed" stage of the video processing pipeline.
  It creates two video files from the source video:
  1. Master (lossless MKV + FFV1) for archival storage
  2. Proxy (all-I-frame H.264) for efficient seeking in the review UI and export

  ## Workflow

  1. Transition source video to "preprocessing" state
  2. Run Python preprocessing task to create master and proxy
  3. Extract keyframe offsets for efficient WebCodecs seeking
  4. Upload both files to S3 (cold storage for master, hot for proxy)
  5. Update source video with file paths and keyframe data

  ## State Management

  - **Input**: Source videos in "downloaded" state without proxy_filepath
  - **Output**: Source videos with proxy_filepath, master_filepath, and keyframe_offsets
  - **Error Handling**: Marks source video as "preprocessing_failed" on errors
  - **Idempotency**: Skip if proxy_filepath IS NOT NULL (preprocessing already complete)

  ## Architecture

  - **Preprocessing**: Python task via PyRunner port
  - **State Management**: Elixir state transitions and database operations
  - **Storage**: S3 for both master and proxy files
  """

  use Heaters.Infrastructure.Orchestration.WorkerBehavior,
    queue: :media_processing,
    unique: [period: 900, fields: [:args]]

  alias Heaters.Videos.{SourceVideo, Queries}
  alias Heaters.Videos.Preprocess.StateManager
  alias Heaters.Infrastructure.Orchestration.{WorkerBehavior, FFmpegConfig}
  alias Heaters.Infrastructure.PyRunner
  require Logger

  @impl WorkerBehavior
  def handle_work(args) do
    handle_preprocessing_work(args)
  end

  defp handle_preprocessing_work(%{"source_video_id" => source_video_id}) do
    Logger.info(
      "PreprocessWorker: Starting preprocessing for source_video_id: #{source_video_id}"
    )

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
        Logger.info("PreprocessWorker: Starting preprocessing for video #{source_video.id}")
        run_preprocessing_task(source_video)

      _proxy_path ->
        Logger.info("PreprocessWorker: Video #{source_video.id} already preprocessed, skipping")
        :ok
    end
  end

  defp run_preprocessing_task(source_video) do
    Logger.info(
      "PreprocessWorker: Running Python preprocessing for source_video_id: #{source_video.id}"
    )

    # Transition to preprocessing state
    case StateManager.start_preprocessing(source_video.id) do
      {:ok, updated_video} ->
        execute_preprocessing(updated_video)

      {:error, reason} ->
        Logger.error("PreprocessWorker: Failed to start preprocessing: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp execute_preprocessing(source_video) do
    # Get FFmpeg configuration for preprocessing
    master_args = FFmpegConfig.get_args(:master)
    proxy_args = FFmpegConfig.get_args(:proxy)

    preprocessing_args = %{
      source_video_id: source_video.id,
      source_video_path: source_video.filepath,
      video_title: source_video.title,
      master_args: master_args,
      proxy_args: proxy_args
    }

    Logger.info(
      "PreprocessWorker: Running Python preprocessing with args: #{inspect(preprocessing_args)}"
    )

    case PyRunner.run("preprocess", preprocessing_args, timeout: :timer.minutes(30)) do
      {:ok, %{"status" => "success"} = result} ->
        Logger.info("PreprocessWorker: Python preprocessing completed successfully")
        process_preprocessing_results(source_video, result)

      {:ok, %{"status" => "error", "error" => error_msg}} ->
        Logger.error("PreprocessWorker: Python preprocessing failed: #{error_msg}")
        mark_preprocessing_failed(source_video, error_msg)

      {:error, reason} ->
        Logger.error("PreprocessWorker: PyRunner failed: #{inspect(reason)}")
        mark_preprocessing_failed(source_video, "PyRunner failed: #{inspect(reason)}")
    end
  end

  defp process_preprocessing_results(source_video, results) do
    # Extract results from Python task
    master_path = Map.get(results, "master_path")
    proxy_path = Map.get(results, "proxy_path")
    keyframe_offsets = Map.get(results, "keyframe_offsets", [])
    metadata = Map.get(results, "metadata", %{})

    update_attrs =
      %{
        master_filepath: master_path,
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
        Logger.info(
          "PreprocessWorker: Successfully completed preprocessing for video #{source_video.id}"
        )

        :ok

      {:error, reason} ->
        Logger.error("PreprocessWorker: Failed to update video state: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp mark_preprocessing_failed(source_video, reason) do
    case StateManager.mark_preprocessing_failed(source_video.id, reason) do
      {:ok, _} ->
        {:error, reason}

      {:error, db_error} ->
        Logger.error("PreprocessWorker: Failed to mark video as failed: #{inspect(db_error)}")
        {:error, reason}
    end
  end

  # Helper function to conditionally put values in a map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
