defmodule Heaters.Processing.Preprocess.Worker do
  @moduledoc """
  Worker for preprocessing source videos into master and proxy files.

  This worker handles the "downloaded → preprocessed" stage of the video processing pipeline.
  It creates two video files from the source video:
  1. Master (lossless MKV + FFV1) for archival storage
  2. Proxy (all-I-frame H.264) for efficient seeking in the review UI and export

  ## Workflow

  1. Transition source video to :preprocessing state
  2. Run Python preprocessing task to create master and proxy
  3. Extract keyframe offsets for efficient seeking
  4. Upload both files to S3 (cold storage for master, hot for proxy)
  5. Update source video with file paths and keyframe data

  ## State Management

  - **Input**: Source videos in :downloaded state without proxy_filepath
  - **Output**: Source videos with proxy_filepath, master_filepath, and keyframe_offsets
  - **Error Handling**: Marks source video as :preprocessing_failed on errors
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
  alias Heaters.Processing.Support.FFmpeg.Config, as: FFmpegConfig
  alias Heaters.Storage.PipelineCache.TempCache
  alias Heaters.Processing.Support.ResultBuilder
  alias Heaters.Processing.Support.Types.PreprocessResult
  require Logger

  # Suppress dialyzer warnings for PyRunner calls when environment is not configured.
  #
  # JUSTIFICATION: PyRunner requires DEV_DATABASE_URL and DEV_S3_BUCKET_NAME environment
  # variables. When not set, PyRunner always fails, making success patterns and their
  # dependent functions unreachable. In configured environments, these will succeed.
  @dialyzer {:nowarn_function,
             [
               run_python_preprocessing: 2,
               process_native_preprocessing_results: 2,
               process_native_temp_cache_results: 3
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

        # Return structured result for completed preprocessing
        preprocess_result =
          ResultBuilder.preprocess_success(source_video.id, source_video.proxy_filepath, %{
            master_filepath: source_video.master_filepath,
            keyframe_count: length(source_video.keyframe_offsets || []),
            optimization_stats: %{
              already_processed: true
            }
          })

        # ResultBuilder.log_result expects a tuple, not a struct directly
        # preprocess_result is already an {:ok, struct} tuple from ResultBuilder.preprocess_success
        preprocess_result
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

        # Generate S3 paths using centralized path service (eliminates Python coupling)
        paths = Heaters.Storage.S3.Paths.generate_video_paths(source_video.id, source_video.title)

        preprocessing_args = %{
          source_video_id: source_video.id,
          # Use local path instead of S3 path
          source_video_path: local_source_path,
          video_title: source_video.title,
          # S3 paths generated by Elixir (eliminates Python path generation coupling)
          master_output_path: paths.master,
          proxy_output_path: paths.proxy,
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
      "PreprocessWorker: Running native Elixir preprocessing with source_video_id: #{source_video.id}"
    )

    # Convert preprocessing_args to format expected by native Elixir Core
    master_filepath = Map.get(preprocessing_args, :master_output_path)
    proxy_filepath = Map.get(preprocessing_args, :proxy_output_path)
    use_temp_cache = Map.get(preprocessing_args, :use_temp_cache, false)

    case Heaters.Processing.Preprocess.Core.process_source_video(
           Map.get(preprocessing_args, :source_video_path),
           source_video.id,
           source_video.title || "Video #{source_video.id}",
           master_filepath,
           proxy_filepath,
           operation_name: "PreprocessWorker",
           use_temp_cache: use_temp_cache
         ) do
      {:ok, result} ->
        Logger.info("PreprocessWorker: Native Elixir preprocessing completed successfully")

        # Handle both temp cache and traditional S3 results
        if use_temp_cache do
          process_native_temp_cache_results(source_video, result, preprocessing_args)
        else
          process_native_preprocessing_results(source_video, result)
        end

      {:error, reason} ->
        Logger.error("PreprocessWorker: Native preprocessing failed: #{reason}")

        case StateManager.mark_preprocessing_failed(source_video.id, reason) do
          {:ok, _} ->
            {:error, reason}

          {:error, db_error} ->
            Logger.error("PreprocessWorker: Failed to mark video as failed: #{inspect(db_error)}")
            {:error, reason}
        end
    end
  end

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

  # S3 path generation moved to Heaters.Storage.S3.Paths module
  # to eliminate coupling between Python and Elixir path generation logic

  # Native Elixir result processing functions

  defp process_native_preprocessing_results(source_video, %PreprocessResult{} = result) do
    # Extract data from native result struct
    proxy_filepath = result.proxy_filepath
    master_filepath = result.master_filepath
    keyframe_count = result.keyframe_count
    encoding_metrics = result.encoding_metrics
    metadata = result.metadata || %{}

    Logger.info(
      "PreprocessWorker: Processing native preprocessing results for #{source_video.id}"
    )

    Logger.info("PreprocessWorker: Proxy: #{proxy_filepath}, Master: #{master_filepath}")

    # Update source video with new file paths and preprocessing metadata
    update_attrs = %{
      proxy_filepath: proxy_filepath,
      master_filepath: master_filepath,
      ingest_state: :preprocessed,
      # Will be updated by keyframes worker
      keyframe_offsets: [],
      processing_metadata:
        Map.merge(source_video.processing_metadata || %{}, %{
          preprocessing_metadata: metadata,
          encoding_metrics: encoding_metrics,
          keyframe_count: keyframe_count,
          temp_cache_used: false,
          proxy_reused: false,
          native_processing: true
        })
    }

    case StateManager.complete_preprocessing(source_video.id, update_attrs) do
      {:ok, updated_video} ->
        Logger.info(
          "PreprocessWorker: Native preprocessing completed for video #{updated_video.id}"
        )

        # Chain directly to next stage using centralized pipeline configuration
        :ok = Heaters.Pipeline.Config.maybe_chain_next_job(__MODULE__, updated_video)
        Logger.info("PreprocessWorker: Successfully chained to next pipeline stage")

        # Return structured result for observability
        ResultBuilder.preprocess_success(
          source_video.id,
          proxy_filepath,
          master_filepath: master_filepath,
          keyframe_count: keyframe_count,
          encoding_metrics: encoding_metrics,
          metadata: metadata,
          duration_ms: result.duration_ms
        )

      {:error, reason} ->
        Logger.error(
          "PreprocessWorker: Failed to update video #{source_video.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp process_native_temp_cache_results(
         source_video,
         %PreprocessResult{} = result,
         _preprocessing_args
       ) do
    # For temp cache, we have local paths that need to be uploaded to S3 later
    local_proxy_path = result.optimization_stats[:proxy_local_path]
    local_master_path = result.optimization_stats[:master_local_path]

    Logger.info("PreprocessWorker: Processing native temp cache results for #{source_video.id}")

    Logger.info(
      "PreprocessWorker: Local proxy: #{local_proxy_path}, Local master: #{local_master_path}"
    )

    # Store temp cache files for later batch upload - only include valid file paths
    temp_results =
      %{}
      |> maybe_put_if_valid("proxy", local_proxy_path)
      |> maybe_put_if_valid("master", local_master_path)

    case TempCache.put_processing_results(temp_results, source_video.id) do
      {:ok, _cached_results} ->
        Logger.info("PreprocessWorker: Temp cache files stored for video #{source_video.id}")

        # Use proper S3 paths from the Paths module that were generated earlier
        paths = Heaters.Storage.S3.Paths.generate_video_paths(source_video.id, source_video.title)

        # Update source video to indicate preprocessing is complete but files are in temp cache
        update_attrs = %{
          proxy_filepath: paths.proxy,
          master_filepath: paths.master,
          ingest_state: :preprocessed,
          keyframe_offsets: result.metadata[:keyframe_offsets] || []
        }

        case StateManager.complete_preprocessing(source_video.id, update_attrs) do
          {:ok, updated_video} ->
            Logger.info(
              "PreprocessWorker: Native temp cache preprocessing completed for video #{updated_video.id}"
            )

            # Chain directly to next stage using centralized pipeline configuration
            :ok = Heaters.Pipeline.Config.maybe_chain_next_job(__MODULE__, updated_video)
            Logger.info("PreprocessWorker: Successfully chained to next pipeline stage")

            # Return structured result for observability
            ResultBuilder.preprocess_success(
              source_video.id,
              paths.proxy,
              master_filepath: paths.master,
              keyframe_count: result.keyframe_count,
              encoding_metrics: result.encoding_metrics,
              metadata: result.metadata,
              duration_ms: result.duration_ms
            )

          {:error, reason} ->
            Logger.error(
              "PreprocessWorker: Failed to update video #{source_video.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("PreprocessWorker: Failed to store temp cache files: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Helper function to only include valid file paths in temp cache results
  defp maybe_put_if_valid(map, _key, nil), do: map
  defp maybe_put_if_valid(map, _key, ""), do: map

  defp maybe_put_if_valid(map, key, path) when is_binary(path) do
    if File.exists?(path) do
      Map.put(map, key, path)
    else
      map
    end
  end

  defp maybe_put_if_valid(map, _key, _invalid), do: map
end
