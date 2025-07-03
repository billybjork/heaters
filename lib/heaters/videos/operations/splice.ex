defmodule Heaters.Videos.Operations.Splice do
  @moduledoc """
  I/O orchestration for the splice workflow using Python-based scene detection.

  This module implements scene detection using Python OpenCV (via PyRunner port) and
  clip extraction using Elixir FFmpeg. It follows the "I/O at the edges" architecture
  pattern while keeping heavy computational work in Python.

  ## Architecture

  - **Scene Detection**: Python `detect_scenes.py` via PyRunner - OpenCV in Python
  - **I/O Orchestration**: This module - Downloads, uploads, coordinates workflow
  - **State Management**: `Splice.StateManager` - Video state transitions
  - **Persistence**: `SplicePersister` - Clip creation and validation
  - **Paths**: `Splice.Filepaths` - S3 path generation
  - **Integration**: Used by `Videos.SpliceWorker` for video processing pipeline

  ## Workflow

  1. Check for cached scene detection results (S3)
  2. Download source video from S3 (if not cached)
  3. Run Python scene detection via PyRunner (with caching)
  4. Extract clips using FFmpeg with S3 idempotency checking
  5. Upload clips to S3
  6. Return structured SpliceResult

  ## Usage

      result = Operations.Splice.run_splice(source_video, threshold: 0.3)
      # %Types.SpliceResult{status: "success", clips_data: [...]}
  """

  alias Heaters.Videos.SourceVideo
  alias Heaters.Videos.Operations.Splice.Filepaths
  alias Heaters.Infrastructure.{PyRunner, Adapters.S3Adapter}
  alias Heaters.Clips.Operations.Shared.{TempManager, ResultBuilding, Types, FFmpegRunner}
  require Logger

  @doc """
  Run the splice workflow for a source video using Python-based scene detection.

  Uses PyRunner to execute Python scene detection, then processes clips in Elixir.
  Includes S3 caching for scene detection results to enable resumability.

  ## Parameters
  - `source_video`: SourceVideo struct
  - `opts`: Scene detection options
    - `:threshold` - Scene cut threshold (0.0-1.0, default: 0.3)
    - `:method` - Detection method ("correl", "chisqr", "intersect", "bhattacharyya", default: "correl")
    - `:min_duration_seconds` - Minimum scene duration (default: 1.0)
    - `:force_redetect` - Skip cache and force re-detection (default: false)

  ## Returns
  - `Types.SpliceResult.t()` - Structured result with clips data and metadata

  ## Examples

      result = Operations.Splice.run_splice(source_video, threshold: 0.3)
      # %Types.SpliceResult{status: "success", clips_data: [...]}
  """
  @spec run_splice(SourceVideo.t(), keyword()) :: Types.SpliceResult.t()
  def run_splice(%SourceVideo{} = source_video, opts \\ []) do
    start_time = System.monotonic_time()

    Logger.info("Port Splice: Starting for source_video_id: #{source_video.id}")

    run_port_splice_workflow(source_video, opts, start_time)
  end

  # Private functions

  defp run_port_splice_workflow(source_video, opts, start_time) do
    Logger.info(
      "Port Splice: Running port-based workflow for source_video_id: #{source_video.id}"
    )

    TempManager.with_temp_directory("port_splice", fn temp_dir ->
      perform_splice_workflow(source_video, temp_dir, opts, start_time)
    end)
  end

  defp perform_splice_workflow(source_video, temp_dir, opts, start_time) do
    with {:ok, detection_result} <- get_or_detect_scenes(source_video, temp_dir, opts),
         {:ok, clips_data} <- process_scenes_to_clips(source_video, detection_result, temp_dir) do
      duration_ms =
        System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

      Logger.info(
        "Port Splice: Successfully processed #{length(clips_data)} clips in #{duration_ms}ms"
      )

      metadata = %{
        total_scenes_detected: length(detection_result.scenes),
        clips_created: length(clips_data),
        detection_params: detection_result.detection_params,
        video_properties: detection_result.video_info,
        cached_detection: Map.get(detection_result, :from_cache, false)
      }

      result = ResultBuilding.build_splice_result(source_video.id, clips_data, metadata)
      ResultBuilding.add_timing(result, duration_ms)
    else
      {:error, reason} ->
        duration_ms =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        Logger.error("Port Splice: Workflow failed after #{duration_ms}ms: #{inspect(reason)}")

        error_result = ResultBuilding.build_splice_error_result(source_video.id, inspect(reason))
        ResultBuilding.add_timing(error_result, duration_ms)
    end
  end

  defp get_or_detect_scenes(source_video, temp_dir, opts) do
    force_redetect = Keyword.get(opts, :force_redetect, false)
    cache_key = Filepaths.build_scene_cache_s3_key(source_video.id)

    case {force_redetect, load_cached_scenes(cache_key)} do
      {false, {:ok, cached_result}} ->
        Logger.info("Port Splice: Using cached scene detection results")
        {:ok, Map.put(cached_result, :from_cache, true)}

      {_, _} ->
        Logger.info("Port Splice: Running scene detection (cached=#{not force_redetect})")
        run_scene_detection_with_cache(source_video, cache_key, temp_dir, opts)
    end
  end

  defp load_cached_scenes(cache_key) do
    case S3Adapter.download_json(cache_key) do
      {:ok, cached_data} ->
        Logger.debug("Port Splice: Found cached scene detection results")
        {:ok, cached_data}

      {:error, :not_found} ->
        Logger.debug("Port Splice: No cached scene detection results found")
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("Port Splice: Failed to load cached results: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_scene_detection_with_cache(source_video, cache_key, temp_dir, opts) do
    with {:ok, local_video_path} <- ensure_source_video_downloaded(source_video, temp_dir),
         {:ok, detection_result} <-
           run_python_scene_detection(source_video, local_video_path, opts),
         :ok <- cache_scene_detection_results(cache_key, detection_result) do
      {:ok, detection_result}
    end
  end

  defp ensure_source_video_downloaded(%SourceVideo{filepath: s3_key}, temp_dir) do
    local_path = Path.join(temp_dir, "source_video.mp4")

    case File.exists?(local_path) do
      true ->
        Logger.debug("Port Splice: Source video already downloaded")
        {:ok, local_path}

      false ->
        download_source_video(s3_key, local_path)
    end
  end

  defp download_source_video(s3_key, local_path) do
    Logger.info("Port Splice: Downloading source video from S3: #{s3_key}")

    case S3Adapter.download_file(s3_key, local_path) do
      {:ok, ^local_path} ->
        Logger.debug("Port Splice: Successfully downloaded to #{local_path}")
        {:ok, local_path}

      {:error, reason} ->
        Logger.error("Port Splice: Failed to download source video: #{inspect(reason)}")
        {:error, "Failed to download source video: #{inspect(reason)}"}
    end
  end

  defp run_python_scene_detection(source_video, local_video_path, opts) do
    # Prepare arguments for Python task
    python_args = %{
      source_video_path: local_video_path,
      source_video_id: source_video.id,
      threshold: Keyword.get(opts, :threshold, 0.3),
      method: Keyword.get(opts, :method, "correl") |> to_string(),
      min_duration_seconds: Keyword.get(opts, :min_duration_seconds, 1.0)
    }

    Logger.info("Port Splice: Running Python scene detection with args: #{inspect(python_args)}")

    # Run Python task via PyRunner
    case PyRunner.run("detect_scenes", python_args, timeout: :timer.minutes(15)) do
      {:ok, %{"status" => "success"} = result} ->
        Logger.info("Port Splice: Python scene detection completed successfully")
        {:ok, parse_python_detection_result(result)}

      {:ok, %{"status" => "error", "error" => error_msg}} ->
        Logger.error("Port Splice: Python scene detection failed: #{error_msg}")
        {:error, "Scene detection failed: #{error_msg}"}

      {:error, reason} ->
        Logger.error("Port Splice: PyRunner failed: #{inspect(reason)}")
        {:error, "Failed to run scene detection: #{inspect(reason)}"}
    end
  end

  defp parse_python_detection_result(%{
         "scenes" => scenes,
         "video_info" => video_info,
         "detection_params" => detection_params
       }) do
    %{
      scenes: parse_scenes(scenes),
      video_info: parse_video_info(video_info),
      detection_params: parse_detection_params(detection_params)
    }
  end

  defp parse_scenes(scenes) when is_list(scenes) do
    Enum.map(scenes, fn scene ->
      %{
        start_frame: Map.get(scene, "start_frame", 0),
        end_frame: Map.get(scene, "end_frame", 0),
        start_time_seconds: Map.get(scene, "start_time", 0.0),
        end_time_seconds: Map.get(scene, "end_time", 0.0),
        duration_seconds: Map.get(scene, "duration", 0.0)
      }
    end)
  end

  defp parse_video_info(video_info) do
    %{
      fps: Map.get(video_info, "fps", 30.0),
      width: Map.get(video_info, "width", 1920),
      height: Map.get(video_info, "height", 1080),
      total_frames: Map.get(video_info, "total_frames", 0),
      duration_seconds: Map.get(video_info, "duration_seconds", 0.0)
    }
  end

  defp parse_detection_params(detection_params) do
    %{
      threshold: Map.get(detection_params, "threshold", 0.3),
      method: Map.get(detection_params, "method", "correl") |> String.to_atom(),
      min_duration_seconds: Map.get(detection_params, "min_duration_seconds", 1.0)
    }
  end

  defp cache_scene_detection_results(cache_key, detection_result) do
    Logger.debug("Port Splice: Caching scene detection results to #{cache_key}")

    case S3Adapter.upload_json(cache_key, detection_result) do
      :ok ->
        Logger.info("Port Splice: Successfully cached scene detection results")
        :ok

      {:error, reason} ->
        Logger.warning("Port Splice: Failed to cache results (non-fatal): #{inspect(reason)}")
        # Don't fail the entire workflow for cache issues
        :ok
    end
  end

  defp process_scenes_to_clips(source_video, detection_result, temp_dir) do
    clips_s3_prefix = Filepaths.build_clips_s3_prefix(source_video)
    source_video_path = Path.join(temp_dir, "source_video.mp4")

    Logger.info("Port Splice: Processing #{length(detection_result.scenes)} scenes to clips")

    # Process scenes sequentially to avoid overwhelming the system
    clips_data =
      detection_result.scenes
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {scene, index}, acc ->
        case process_single_scene(
               source_video,
               scene,
               index,
               clips_s3_prefix,
               source_video_path,
               temp_dir
             ) do
          {:ok, clip_data} ->
            {:cont, [clip_data | acc]}

          {:error, reason} ->
            Logger.error("Port Splice: Failed to process scene #{index + 1}: #{inspect(reason)}")
            {:halt, {:error, reason}}
        end
      end)

    case clips_data do
      {:error, reason} -> {:error, reason}
      clips_list -> {:ok, Enum.reverse(clips_list)}
    end
  end

  defp process_single_scene(
         source_video,
         scene,
         index,
         clips_s3_prefix,
         source_video_path,
         temp_dir
       ) do
    clip_identifier = Filepaths.generate_clip_identifier(source_video.id, index)
    local_clip_path = Path.join(temp_dir, "#{clip_identifier}.mp4")
    s3_clip_key = Filepaths.build_clip_s3_key(clips_s3_prefix, clip_identifier)

    Logger.debug("Port Splice: Processing scene #{index + 1}: #{clip_identifier}")

    # Check if clip already exists in S3 (idempotency)
    case S3Adapter.head_object(s3_clip_key) do
      {:ok, metadata} ->
        Logger.info(
          "Port Splice: Clip #{clip_identifier} already exists in S3 (#{metadata.content_length} bytes), skipping extraction"
        )

        build_clip_data_from_existing(clip_identifier, s3_clip_key, scene)

      {:error, :not_found} ->
        extract_and_upload_clip(
          scene,
          clip_identifier,
          source_video_path,
          local_clip_path,
          s3_clip_key
        )

      {:error, reason} ->
        Logger.warning(
          "Port Splice: Failed to check S3 existence for #{s3_clip_key}: #{inspect(reason)}, proceeding with extraction"
        )

        extract_and_upload_clip(
          scene,
          clip_identifier,
          source_video_path,
          local_clip_path,
          s3_clip_key
        )
    end
  end

  defp extract_and_upload_clip(
         scene,
         clip_identifier,
         source_video_path,
         local_clip_path,
         s3_clip_key
       ) do
    Logger.debug(
      "Port Splice: Extracting clip #{clip_identifier}: #{scene.start_time_seconds}s - #{scene.end_time_seconds}s"
    )

    with {:ok, file_size} <-
           FFmpegRunner.create_video_clip(
             source_video_path,
             local_clip_path,
             scene.start_time_seconds,
             scene.end_time_seconds
           ),
         :ok <- S3Adapter.upload_file(local_clip_path, s3_clip_key) do
      Logger.info(
        "Port Splice: Successfully created and uploaded clip: #{clip_identifier} (#{file_size} bytes)"
      )

      build_clip_data(clip_identifier, s3_clip_key, scene)
    else
      {:error, reason} ->
        Logger.error(
          "Port Splice: Failed to extract/upload clip #{clip_identifier}: #{inspect(reason)}"
        )

        {:error, "Failed to extract/upload clip #{clip_identifier}: #{inspect(reason)}"}
    end
  end

  defp build_clip_data(clip_identifier, s3_clip_key, scene) do
    {:ok,
     %{
       clip_identifier: clip_identifier,
       clip_filepath: s3_clip_key,
       start_frame: scene.start_frame,
       end_frame: scene.end_frame,
       start_time_seconds: Float.round(scene.start_time_seconds, 3),
       end_time_seconds: Float.round(scene.end_time_seconds, 3),
       duration_seconds: Float.round(scene.duration_seconds, 3),
       metadata: %{
         scene_index: scene.start_frame
       }
     }}
  end

  defp build_clip_data_from_existing(clip_identifier, s3_clip_key, scene) do
    {:ok,
     %{
       clip_identifier: clip_identifier,
       clip_filepath: s3_clip_key,
       start_frame: scene.start_frame,
       end_frame: scene.end_frame,
       start_time_seconds: Float.round(scene.start_time_seconds, 3),
       end_time_seconds: Float.round(scene.end_time_seconds, 3),
       duration_seconds: Float.round(scene.duration_seconds, 3),
       metadata: %{
         scene_index: scene.start_frame,
         skipped: true,
         reason: "already_exists_in_s3"
       }
     }}
  end
end
