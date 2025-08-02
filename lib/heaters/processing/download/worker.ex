defmodule Heaters.Processing.Download.Worker do
  @moduledoc """
  Download Worker for source video ingestion.

  Orchestrates the initial download phase of the video processing pipeline:
  - Downloads videos from URLs using yt-dlp with quality-focused strategy
  - Applies conditional normalization for primary downloads (fixes merge issues)
  - Stores original files in S3 for downstream processing
  - Chains to preprocessing stage for pipeline optimization

  ## Architecture

  This worker follows the Elixir-orchestrated pattern:
  - **Configuration**: Provided by `YtDlpConfig` and `FFmpegConfig` modules
  - **Execution**: Python task receives complete config and focuses on execution
  - **State Management**: Elixir handles all state transitions and business logic

  See `YtDlpConfig` for yt-dlp configuration details and quality requirements.
  """

  use Heaters.Pipeline.WorkerBehavior,
    queue: :media_processing,
    # 10 minutes with source_video_id uniqueness only
    unique: [period: 600, fields: [:args], keys: [:source_video_id]]

  alias Heaters.Media.Queries.Video, as: VideoQueries
  alias Heaters.Processing.Py.Runner, as: PyRunner
  alias Heaters.Storage.PipelineCache.TempCache
  alias Heaters.Processing.Download.{Core, YtDlpConfig}

  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Processing.Render.FFmpegConfig

  require Logger

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [handle_work: 1]}

  @impl WorkerBehavior
  def handle_work(%{"source_video_id" => source_video_id} = args) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      case check_idempotency(source_video) do
        :ok ->
          handle_ingest_work(args)

        {:error, :already_processed} ->
          WorkerBehavior.handle_already_processed("Source video", source_video_id)
      end
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Source video", source_video_id)
    end
  end

  defp handle_ingest_work(%{"source_video_id" => source_video_id}) do
    Logger.info("DownloadWorker: Starting download for source_video_id: #{source_video_id}")

    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id),
         {:ok, updated_video} <- ensure_downloading_state(source_video) do
      Logger.info(
        "DownloadWorker: Running PyRunner for source_video_id: #{source_video_id}, URL: #{updated_video.original_url}"
      )

      # Python task receives complete configuration from Elixir
      # All yt-dlp options, format strategies, and normalization config
      # are provided by YtDlpConfig and FFmpegConfig modules
      download_config = YtDlpConfig.get_download_config()

      # Validate configuration before sending to Python
      :ok = YtDlpConfig.validate_config!(download_config)

      py_args = %{
        source_video_id: updated_video.id,
        input_source: updated_video.original_url,
        # Enable temp caching for pipeline chaining
        use_temp_cache: true,
        # Complete yt-dlp configuration from YtDlpConfig (validated)
        download_config: download_config,
        # FFmpeg normalization arguments from FFmpegConfig
        normalize_args: FFmpegConfig.get_args(:download_normalization)
      }

      case PyRunner.run("download", py_args, timeout: :timer.minutes(20)) do
        {:ok, result} ->
          Logger.info(
            "DownloadWorker: PyRunner succeeded for source_video_id: #{source_video_id}, result: #{inspect(result)}"
          )

          # Elixir handles the state transition and metadata update
          # Convert string keys to atom keys for the metadata (recursively)
          metadata = convert_keys_to_atoms(result)

          # Handle both temp cache and traditional S3 results
          # Check for local_filepath to detect temp cache usage
          completion_result =
            if Map.get(result, "local_filepath") do
              handle_temp_cache_download_completion(source_video_id, metadata)
            else
              Core.complete_downloading(source_video_id, metadata)
            end

          case completion_result do
            {:ok, updated_video} ->
              Logger.info(
                "DownloadWorker: Successfully completed download for source_video_id: #{source_video_id}"
              )

              # Chain directly to next stage using centralized pipeline configuration
              :ok = Heaters.Pipeline.Config.maybe_chain_next_job(__MODULE__, updated_video)
              Logger.info("DownloadWorker: Successfully chained to next pipeline stage")
              :ok

            {:error, reason} ->
              Logger.error("DownloadWorker: Failed to update video metadata: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          # If the python script fails, we use the new state management to record the error
          Logger.error(
            "DownloadWorker: PyRunner failed for source_video_id: #{source_video_id}, reason: #{inspect(reason)}"
          )

          case Core.mark_failed(updated_video, "download_failed", reason) do
            {:ok, _} ->
              {:error, reason}

            {:error, db_error} ->
              Logger.error("DownloadWorker: Failed to mark video as failed: #{inspect(db_error)}")
              {:error, reason}
          end
      end
    else
      {:error, reason} ->
        Logger.error(
          "DownloadWorker: Failed to prepare for download for source video #{source_video_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Helper function to ensure video is in downloading state, handling resumable processing
  defp ensure_downloading_state(source_video) do
    case source_video.ingest_state do
      "downloading" ->
        Logger.info(
          "DownloadWorker: Video #{source_video.id} already in downloading state, resuming"
        )

        {:ok, source_video}

      _ ->
        # Transition to downloading state for new/failed videos
        Core.start_downloading(source_video.id)
    end
  end

  # Idempotency Check: Ensures we don't re-process completed work.
  # Now supports resumable processing of interrupted jobs.
  defp check_idempotency(%{ingest_state: "new"}), do: :ok
  # Allow resuming interrupted jobs
  defp check_idempotency(%{ingest_state: "downloading"}), do: :ok
  defp check_idempotency(%{ingest_state: "download_failed"}), do: :ok
  defp check_idempotency(_), do: {:error, :already_processed}

  defp convert_keys_to_atoms(map) when is_map(map) do
    for {key, value} <- map, into: %{} do
      {String.to_atom(key), convert_keys_to_atoms(value)}
    end
  end

  defp convert_keys_to_atoms(list) when is_list(list) do
    for item <- list, do: convert_keys_to_atoms(item)
  end

  defp convert_keys_to_atoms(other), do: other

  # Handle download completion when using temp cache
  defp handle_temp_cache_download_completion(source_video_id, metadata) do
    # Python task returns local path when using temp cache
    local_path = Map.get(metadata, :local_filepath)
    # Future S3 path
    s3_key = Map.get(metadata, :filepath)

    if local_path && s3_key do
      # Cache the downloaded file for preprocessing stage
      case TempCache.put(s3_key, local_path) do
        {:ok, _cached_path} ->
          Logger.info("DownloadWorker: Cached download result for pipeline chaining")

          # Update database with S3 path (even though not uploaded yet)
          Core.complete_downloading(source_video_id, metadata)

        {:error, reason} ->
          Logger.warning("DownloadWorker: Failed to cache download result: #{inspect(reason)}")
          # Fall back to traditional approach
          Core.complete_downloading(source_video_id, metadata)
      end
    else
      # Missing required paths, fall back to traditional approach
      Core.complete_downloading(source_video_id, metadata)
    end
  end
end
