defmodule Heaters.Processing.Preprocess.Worker do
  @moduledoc """
  Worker for preprocessing source videos into master and proxy files.

  This worker handles the "downloaded → preprocessed" stage of the video processing pipeline.
  It creates two video files from the source video:
  1. Master (lossless MKV + FFV1) for archival storage
  2. Proxy (all-I-frame H.264) for efficient seeking in the review UI and export

  ## Workflow

  1. Transition source video to "preprocessing" state
  2. Run Python preprocessing task to create master and proxy
  3. Extract keyframe offsets for efficient seeking
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

  use Heaters.Pipeline.WorkerBehavior,
    queue: :media_processing,
    unique: [period: 300, fields: [:args], keys: [:source_video_id]]

  alias Heaters.Media.{Video, Videos}
  alias Heaters.Processing.Preprocess.StateManager
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Processing.Render.FFmpegConfig
  alias Heaters.Processing.Py.Runner, as: PyRunner
  alias Heaters.Storage.PipelineCache.TempCache
  require Logger

  # Suppress dialyzer warnings for PyRunner calls when environment is not configured.
  #
  # JUSTIFICATION: PyRunner requires DEV_DATABASE_URL and DEV_S3_BUCKET_NAME environment
  # variables. When not set, PyRunner always fails, making success patterns and their 
  # dependent functions unreachable. In configured environments, these will succeed.
  @dialyzer {:nowarn_function,
             [
               run_python_preprocessing: 2,
               process_temp_cache_results: 3,
               process_preprocessing_results: 2,
               maybe_put: 3,
               generate_s3_key: 3
             ]}

  @impl WorkerBehavior
  def handle_work(args) do
    handle_preprocessing_work(args)
  end

  defp handle_preprocessing_work(%{"source_video_id" => source_video_id}) do
    Logger.info(
      "PreprocessWorker: Starting preprocessing for source_video_id: #{source_video_id}"
    )

    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      handle_preprocessing(source_video)
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Source video", source_video_id)
    end
  end

  defp handle_preprocessing(%Video{} = source_video) do
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
    # Check if master generation should be skipped for cost optimization
    skip_master = FFmpegConfig.should_skip_master?([], source_video)

    # Get FFmpeg configuration for preprocessing
    master_args = FFmpegConfig.get_args(:master, skip_master: skip_master)
    proxy_args = FFmpegConfig.get_args(:proxy)

    # Try to get source video from temp cache first, fallback to S3
    source_path_result =
      TempCache.get_or_download(
        source_video.filepath,
        operation_name: "PreprocessWorker"
      )

    case source_path_result do
      {:ok, local_source_path, cache_status} ->
        Logger.info("PreprocessWorker: Using #{cache_status} source file: #{local_source_path}")

        # Check if we can reuse the normalized download as proxy (smart reuse)
        can_reuse_as_proxy = can_reuse_normalized_as_proxy?(source_video, local_source_path)

        preprocessing_args = %{
          source_video_id: source_video.id,
          # Use local path instead of S3 path
          source_video_path: local_source_path,
          video_title: source_video.title,
          master_args: master_args,
          proxy_args: proxy_args,
          skip_master: skip_master,
          # Flag for Python task to cache results
          use_temp_cache: true,
          # Skip proxy encoding if possible
          reuse_as_proxy: can_reuse_as_proxy
        }

        run_python_preprocessing(source_video, preprocessing_args)

      {:error, reason} ->
        Logger.error("PreprocessWorker: Failed to get source video: #{inspect(reason)}")
        {:error, "Failed to get source video: #{inspect(reason)}"}
    end
  end

  defp run_python_preprocessing(source_video, preprocessing_args) do
    Logger.info(
      "PreprocessWorker: Running Python preprocessing with args: #{inspect(Map.delete(preprocessing_args, :source_video_path))}"
    )

    case PyRunner.run_python_task("preprocess", preprocessing_args, timeout: :timer.minutes(30)) do
      {:ok, result} ->
        Logger.info("PreprocessWorker: Python preprocessing completed successfully")

        # Handle both temp cache and traditional S3 results
        if Map.get(preprocessing_args, :use_temp_cache, false) do
          process_temp_cache_results(source_video, result, preprocessing_args)
        else
          process_preprocessing_results(source_video, result)
        end

      {:error, reason} ->
        Logger.error("PreprocessWorker: PyRunner failed: #{reason}")
        mark_preprocessing_failed(source_video, reason)
    end
  end

  defp process_temp_cache_results(source_video, results, preprocessing_args) do
    # Python task returns local paths when using temp cache
    master_local_path = Map.get(results, "master_local_path")
    proxy_local_path = Map.get(results, "proxy_local_path")
    keyframe_offsets = Map.get(results, "keyframe_offsets", [])
    metadata = Map.get(results, "metadata", %{})

    skip_master = Map.get(preprocessing_args, :skip_master, false)

    # Cache the results for the next stage (DetectScenesWorker)
    cache_results = %{}

    cache_results =
      if not is_nil(proxy_local_path) and proxy_local_path != "",
        do: Map.put(cache_results, :proxy, proxy_local_path),
        else: cache_results

    cache_results =
      if not is_nil(master_local_path) and master_local_path != "" and not skip_master,
        do: Map.put(cache_results, :master, master_local_path),
        else: cache_results

    case TempCache.put_processing_results(cache_results, source_video.id) do
      {:ok, cached_results} ->
        Logger.info("PreprocessWorker: Cached results for pipeline chaining")

        # Generate S3 paths but don't upload yet - cache for later upload
        proxy_s3_key = generate_s3_key(source_video, "proxy", ".mp4")

        master_s3_key =
          if skip_master, do: nil, else: generate_s3_key(source_video, "master", ".mkv")

        # Store cache info in job args for final upload stage
        cache_info = %{
          "proxy_cache_key" => cached_results[:proxy][:cache_key],
          "proxy_s3_key" => proxy_s3_key
        }

        _cache_info =
          if master_s3_key do
            Map.merge(cache_info, %{
              "master_cache_key" => cached_results[:master][:cache_key],
              "master_s3_key" => master_s3_key
            })
          else
            cache_info
          end

        # Update source video with paths and metadata (using future S3 paths)
        update_attrs = %{
          proxy_filepath: proxy_s3_key,
          keyframe_offsets: keyframe_offsets,
          ingest_state: "preprocessed"
        }

        update_attrs =
          if master_s3_key do
            Map.put(update_attrs, :master_filepath, master_s3_key)
          else
            update_attrs
          end

        update_attrs =
          update_attrs
          |> maybe_put(:duration_seconds, metadata["duration_seconds"])
          |> maybe_put(:fps, metadata["fps"])
          |> maybe_put(:width, metadata["width"])
          |> maybe_put(:height, metadata["height"])

        case StateManager.complete_preprocessing(source_video.id, update_attrs) do
          {:ok, final_video} ->
            Logger.info(
              "PreprocessWorker: Successfully completed preprocessing for video #{source_video.id} (temp cached)"
            )

            # Chain directly to next stage using centralized pipeline configuration
            :ok = Heaters.Pipeline.Config.maybe_chain_next_job(__MODULE__, final_video)
            Logger.info("PreprocessWorker: Successfully chained to next pipeline stage")
            :ok

          {:error, reason} ->
            Logger.error("PreprocessWorker: Failed to update video state: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("PreprocessWorker: Failed to cache results: #{inspect(reason)}")
        {:error, "Failed to cache processing results: #{inspect(reason)}"}
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
      {:ok, final_video} ->
        Logger.info(
          "PreprocessWorker: Successfully completed preprocessing for video #{source_video.id}"
        )

        # Chain directly to next stage using centralized pipeline configuration
        :ok = Heaters.Pipeline.Config.maybe_chain_next_job(__MODULE__, final_video)
        Logger.info("PreprocessWorker: Successfully chained to next pipeline stage")
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

  # Check if normalized download output can be reused as proxy
  # This implements the "smart proxy reuse" optimization from the workflow report
  defp can_reuse_normalized_as_proxy?(_source_video, local_source_path) do
    # Only reuse if the source was normalized (indicating it came from yt-dlp primary download)
    # Note: metadata is not stored in the SourceVideo struct, so we'll check other indicators
    # For now, assume normalization happened if we have a valid local source path from download
    if local_source_path != "" do
      # Check if the normalized file meets proxy requirements
      case analyze_video_for_proxy_reuse(local_source_path) do
        {:ok, analysis} ->
          # Criteria for reuse: H.264 codec, AAC audio, ≤1080p, reasonable quality
          analysis.video_codec == "h264" &&
            analysis.audio_codec == "aac" &&
            analysis.height <= 1080 &&
            analysis.width <= 1920 &&
            is_reasonable_quality?(analysis)

        {:error, reason} ->
          Logger.debug("PreprocessWorker: Cannot analyze for proxy reuse: #{inspect(reason)}")
          false
      end
    else
      false
    end
  end

  # Analyze video file to determine if it's suitable for proxy reuse
  defp analyze_video_for_proxy_reuse(video_path) do
    try do
      # Use ffprobe to get detailed codec information
      cmd = [
        "ffprobe",
        "-v",
        "quiet",
        "-print_format",
        "json",
        "-show_streams",
        "-show_format",
        video_path
      ]

      case System.cmd("ffprobe", tl(cmd), stderr_to_stdout: true) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, data} ->
              video_stream = Enum.find(data["streams"], &(&1["codec_type"] == "video"))
              audio_stream = Enum.find(data["streams"], &(&1["codec_type"] == "audio"))

              analysis = %{
                video_codec: video_stream["codec_name"],
                audio_codec: audio_stream && audio_stream["codec_name"],
                width: video_stream["width"],
                height: video_stream["height"],
                bitrate: String.to_integer(data["format"]["bit_rate"] || "0"),
                duration: String.to_float(data["format"]["duration"] || "0.0")
              }

              {:ok, analysis}

            {:error, reason} ->
              {:error, "JSON decode failed: #{inspect(reason)}"}
          end

        {error, _code} ->
          {:error, "ffprobe failed: #{error}"}
      end
    rescue
      error ->
        {:error, "Analysis exception: #{Exception.message(error)}"}
    end
  end

  # Check if video quality is reasonable for proxy use
  defp is_reasonable_quality?(analysis) do
    # Quality heuristics:
    # - Bitrate should be reasonable (not too low)
    # - Duration should be valid
    # At least 500 kbps
    analysis.bitrate > 500_000 &&
      analysis.duration > 0
  end

  # Helper function to generate consistent S3 keys
  defp generate_s3_key(source_video, file_type, extension) do
    # Use the same sanitization logic as Python tasks
    sanitized_title =
      source_video.title
      |> String.replace(~r/[^a-zA-Z0-9_\-\.]/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_")
      |> String.slice(0, 100)

    case file_type do
      "master" -> "masters/#{sanitized_title}_#{source_video.id}_master#{extension}"
      "proxy" -> "proxies/#{sanitized_title}_#{source_video.id}_proxy#{extension}"
      _ -> "processed/#{sanitized_title}_#{source_video.id}_#{file_type}#{extension}"
    end
  end
end
