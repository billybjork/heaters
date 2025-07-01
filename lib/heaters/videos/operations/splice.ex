defmodule Heaters.Videos.Operations.Splice do
  @moduledoc """
  I/O orchestration for the splice workflow using native Elixir scene detection.

  This module implements scene detection and clip extraction using the Evision library
  (OpenCV-Elixir bindings). It follows the "I/O at the edges" architecture pattern,
  using domain logic modules for pure scene detection and orchestrating all I/O operations here.

  ## Architecture

  - **Domain Logic**: `Splice.SceneDetector` - Pure OpenCV scene detection
  - **I/O Orchestration**: This module - Downloads, uploads, coordinates workflow
  - **Integration**: Used by `Videos.SpliceWorker` for video processing pipeline

  ## Workflow

  1. Download source video from S3
  2. Run native scene detection using Evision
  3. Extract clips using FFmpeg with S3 idempotency checking
  4. Upload clips to S3
  5. Return structured SpliceResult

  ## Usage

      result = Operations.Splice.run_splice(source_video, threshold: 0.3)
      # %Types.SpliceResult{status: "success", clips_data: [...]}
  """

  alias Heaters.Videos.{SourceVideo, Ingest}
  alias Heaters.Videos.Operations.Splice.SceneDetector
  alias Heaters.Infrastructure.Adapters.S3Adapter
  alias Heaters.Clips.Operations.Shared.{TempManager, ResultBuilding, Types, FFmpegRunner}
  require Logger

  @doc """
  Run the splice workflow for a source video using native Elixir scene detection.

  Downloads the source video, detects scenes using Evision (OpenCV bindings),
  extracts clips using FFmpeg, and uploads them to S3 with idempotency checking.

  ## Parameters
  - `source_video`: SourceVideo struct
  - `opts`: Scene detection options (threshold, method, min_duration_seconds)

  ## Returns
  - `Types.SpliceResult.t()` - Structured result with clips data and metadata

  ## Examples

      result = Operations.Splice.run_splice(source_video, threshold: 0.3)
      # %Types.SpliceResult{status: "success", clips_data: [...]}
  """
  @spec run_splice(SourceVideo.t(), keyword()) :: Types.SpliceResult.t()
  def run_splice(%SourceVideo{} = source_video, opts \\ []) do
    start_time = System.monotonic_time()

    Logger.info("Native Splice: Starting for source_video_id: #{source_video.id}")

    run_native_splice_workflow(source_video, opts, start_time)
  end

    # Private functions

  defp run_native_splice_workflow(source_video, opts, start_time) do
    Logger.info("Native Splice: Running native workflow for source_video_id: #{source_video.id}")

    TempManager.with_temp_directory("native_splice", fn temp_dir ->
      perform_splice_workflow(source_video, temp_dir, opts, start_time)
    end)
  end

  defp perform_splice_workflow(source_video, temp_dir, opts, start_time) do
    with {:ok, local_video_path} <- download_source_video(source_video, temp_dir),
         {:ok, detection_result} <- run_scene_detection(local_video_path, opts),
         {:ok, clips_data} <- process_scenes_to_clips(source_video, detection_result, temp_dir) do

      duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

      Logger.info("Native Splice: Successfully processed #{length(clips_data)} clips in #{duration_ms}ms")

      metadata = %{
        total_scenes_detected: length(detection_result.scenes),
        clips_created: length(clips_data),
        detection_params: detection_result.detection_params,
        video_properties: detection_result.video_info
      }

      result = ResultBuilding.build_splice_result(source_video.id, clips_data, metadata)
      ResultBuilding.add_timing(result, duration_ms)
    else
      {:error, reason} ->
        duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
        Logger.error("Native Splice: Workflow failed after #{duration_ms}ms: #{inspect(reason)}")

        error_result = ResultBuilding.build_splice_error_result(source_video.id, inspect(reason))
        ResultBuilding.add_timing(error_result, duration_ms)
    end
  end

  defp download_source_video(%SourceVideo{filepath: s3_key}, temp_dir) do
    local_path = Path.join(temp_dir, "source_video.mp4")

    Logger.info("Native Splice: Downloading source video from S3: #{s3_key}")

    case S3Adapter.download_file(s3_key, local_path) do
      {:ok, ^local_path} ->
        Logger.debug("Native Splice: Successfully downloaded to #{local_path}")
        {:ok, local_path}

      {:error, reason} ->
        Logger.error("Native Splice: Failed to download source video: #{inspect(reason)}")
        {:error, "Failed to download source video: #{inspect(reason)}"}
    end
  end

  defp run_scene_detection(video_path, opts) do
    detection_opts = [
      threshold: Keyword.get(opts, :threshold, 0.3),
      method: Keyword.get(opts, :method, :correl),
      min_duration_seconds: Keyword.get(opts, :min_duration_seconds, 1.0)
    ]

    Logger.info("Native Splice: Running scene detection with opts: #{inspect(detection_opts)}")

    case SceneDetector.detect_scenes(video_path, detection_opts) do
      {:ok, result} ->
        Logger.info("Native Splice: Scene detection completed: #{length(result.scenes)} scenes found")
        {:ok, result}

      {:error, reason} ->
        Logger.error("Native Splice: Scene detection failed: #{inspect(reason)}")
        {:error, "Scene detection failed: #{inspect(reason)}"}
    end
  end

  defp process_scenes_to_clips(source_video, detection_result, temp_dir) do
    clips_s3_prefix = Ingest.build_s3_prefix(source_video)
    source_video_path = Path.join(temp_dir, "source_video.mp4")

    Logger.info("Native Splice: Processing #{length(detection_result.scenes)} scenes to clips")

    # Process scenes sequentially to avoid overwhelming the system
    clips_data =
      detection_result.scenes
      |> Enum.with_index(1)
      |> Enum.reduce_while([], fn {scene, index}, acc ->
        case process_single_scene(source_video, scene, index, clips_s3_prefix, source_video_path, temp_dir) do
          {:ok, clip_data} ->
            {:cont, [clip_data | acc]}

          {:error, reason} ->
            Logger.error("Native Splice: Failed to process scene #{index}: #{inspect(reason)}")
            {:halt, {:error, reason}}
        end
      end)

    case clips_data do
      {:error, reason} -> {:error, reason}
      clips_list -> {:ok, Enum.reverse(clips_list)}
    end
  end

  defp process_single_scene(source_video, scene, index, clips_s3_prefix, source_video_path, temp_dir) do
    clip_identifier = "#{source_video.id}_clip_#{String.pad_leading("#{index}", 3, "0")}"
    local_clip_path = Path.join(temp_dir, "#{clip_identifier}.mp4")
    s3_clip_key = "#{clips_s3_prefix}/#{clip_identifier}.mp4"

    Logger.debug("Native Splice: Processing scene #{index}: #{clip_identifier}")

    # Check if clip already exists in S3 (idempotency)
    case S3Adapter.head_object(s3_clip_key) do
      {:ok, metadata} ->
        Logger.info("Native Splice: Clip #{clip_identifier} already exists in S3 (#{metadata.content_length} bytes), skipping extraction")
        build_clip_data_from_existing(clip_identifier, s3_clip_key, scene)

      {:error, :not_found} ->
        extract_and_upload_clip(source_video, scene, clip_identifier, source_video_path, local_clip_path, s3_clip_key)

      {:error, reason} ->
        Logger.warning("Native Splice: Failed to check S3 existence for #{s3_clip_key}: #{inspect(reason)}, proceeding with extraction")
        extract_and_upload_clip(source_video, scene, clip_identifier, source_video_path, local_clip_path, s3_clip_key)
    end
  end

  defp extract_and_upload_clip(_source_video, scene, clip_identifier, source_video_path, local_clip_path, s3_clip_key) do
    Logger.debug("Native Splice: Extracting clip #{clip_identifier}: #{scene.start_time_seconds}s - #{scene.end_time_seconds}s")

    with {:ok, file_size} <- FFmpegRunner.create_video_clip(
           source_video_path,
           local_clip_path,
           scene.start_time_seconds,
           scene.end_time_seconds
         ),
         :ok <- S3Adapter.upload_file(local_clip_path, s3_clip_key) do

      Logger.info("Native Splice: Successfully created and uploaded clip: #{clip_identifier} (#{file_size} bytes)")
      build_clip_data(clip_identifier, s3_clip_key, scene)
    else
      {:error, reason} ->
        Logger.error("Native Splice: Failed to extract/upload clip #{clip_identifier}: #{inspect(reason)}")
        {:error, "Failed to extract/upload clip #{clip_identifier}: #{inspect(reason)}"}
    end
  end

  defp build_clip_data(clip_identifier, s3_clip_key, scene) do
    {:ok, %{
      clip_identifier: clip_identifier,
      clip_filepath: s3_clip_key,
      start_frame: scene.start_frame,
      end_frame: scene.end_frame,
      start_time_seconds: Float.round(scene.start_time_seconds, 3),
      end_time_seconds: Float.round(scene.end_time_seconds, 3),
      metadata: %{
        duration_seconds: Float.round(scene.duration_seconds, 3),
        scene_index: scene.start_frame
      }
    }}
  end

  defp build_clip_data_from_existing(clip_identifier, s3_clip_key, scene) do
    {:ok, %{
      clip_identifier: clip_identifier,
      clip_filepath: s3_clip_key,
      start_frame: scene.start_frame,
      end_frame: scene.end_frame,
      start_time_seconds: Float.round(scene.start_time_seconds, 3),
      end_time_seconds: Float.round(scene.end_time_seconds, 3),
      metadata: %{
        duration_seconds: Float.round(scene.duration_seconds, 3),
        scene_index: scene.start_frame,
        skipped: true,
        reason: "already_exists_in_s3"
      }
    }}
  end
end
