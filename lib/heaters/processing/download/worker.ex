defmodule Heaters.Processing.Download.Worker do
  @moduledoc """
  Download Worker for source video ingestion.

  Orchestrates the initial download phase of the video processing pipeline:
  - Downloads videos from URLs using yt-dlp via System.cmd
  - Applies conditional normalization for primary downloads (fixes merge issues)
  - Stores original files in S3 for downstream processing
  - Chains to encoding stage for pipeline optimization

  ## Architecture

  Uses the native Elixir `Downloader` module instead of Python, eliminating the
  cross-language serialization layer. Configuration comes from `YtDlpConfig`,
  execution happens through yt-dlp/ffmpeg CLI calls via `System.cmd`.
  """

  use Heaters.Pipeline.WorkerBehavior,
    queue: :media_processing,
    unique: [period: 600, fields: [:args], keys: [:source_video_id]]

  alias Heaters.Media.Videos
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Processing.Download.{Core, Downloader, YtDlpConfig}
  alias Heaters.Processing.Support.FFmpeg.Config, as: FFmpegConfig
  alias Heaters.Processing.Support.ResultBuilder
  alias Heaters.Storage.PipelineCache.TempCache
  alias Heaters.Storage.S3.Core, as: S3
  alias Heaters.Storage.S3.Paths, as: S3Paths

  require Logger

  @impl WorkerBehavior
  def handle_work(%{"source_video_id" => source_video_id} = args) do
    case Videos.get_source_video(source_video_id) do
      {:ok, source_video} ->
        case check_idempotency(source_video) do
          :ok ->
            handle_ingest_work(args)

          {:error, :already_processed} ->
            WorkerBehavior.handle_already_processed("Source video", source_video_id)
        end

      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Source video", source_video_id)
    end
  end

  defp handle_ingest_work(%{"source_video_id" => source_video_id}) do
    Logger.info("DownloadWorker: Starting download for source_video_id: #{source_video_id}")

    with {:ok, source_video} <- Videos.get_source_video(source_video_id),
         {:ok, video} <- ensure_downloading_state(source_video),
         {:ok, result} <- execute_download(video) do
      complete_download(source_video_id, result)
    else
      {:error, reason} ->
        Logger.error(
          "DownloadWorker: Failed for source video #{source_video_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp execute_download(video) do
    config = YtDlpConfig.get_download_config()
    :ok = YtDlpConfig.validate_config!(config)

    download_opts = %{
      url: video.original_url,
      source_video_id: video.id,
      timestamp: generate_timestamp(),
      config: config,
      normalize_args: FFmpegConfig.get_args(:download_normalization)
    }

    Logger.info(
      "DownloadWorker: Downloading source_video_id: #{video.id}, URL: #{video.original_url}"
    )

    try do
      case Downloader.download(download_opts) do
        {:ok, result} ->
          Logger.info("DownloadWorker: Download succeeded for source_video_id: #{video.id}")
          {:ok, result}

        {:error, reason} ->
          Logger.error(
            "DownloadWorker: Download failed for source_video_id: #{video.id}: #{inspect(reason)}"
          )

          Core.mark_failed(video, :download_failed, reason)
          {:error, reason}
      end
    rescue
      error ->
        reason = Exception.message(error)

        Logger.error(
          "DownloadWorker: Download crashed for source_video_id: #{video.id}: #{Exception.format(:error, error, __STACKTRACE__)}"
        )

        Core.mark_failed(video, :download_failed, reason)
        {:error, reason}
    catch
      kind, value ->
        reason = "#{kind}: #{inspect(value)}"

        Logger.error(
          "DownloadWorker: Download crashed for source_video_id: #{video.id} (#{kind}): #{inspect(value)}"
        )

        Core.mark_failed(video, :download_failed, reason)
        {:error, reason}
    end
  end

  defp complete_download(source_video_id, result) do
    title = get_in(result, [:metadata, :title]) || "video_#{source_video_id}"
    timestamp = get_in(result, [:metadata, :timestamp]) || generate_timestamp()
    s3_key = S3Paths.generate_original_path(title, timestamp, ".mp4")

    cache_locally(s3_key, result.local_filepath)

    with {:ok, _} <- upload_to_s3(result.local_filepath, s3_key),
         {:ok, updated_video} <- save_metadata(source_video_id, result, s3_key) do
      :ok = Heaters.Pipeline.Config.maybe_chain_next_job(__MODULE__, updated_video)
      Logger.info("DownloadWorker: Completed and chained for source_video_id: #{source_video_id}")

      build_result(source_video_id, updated_video, result)
    else
      {:error, reason} ->
        Logger.error("DownloadWorker: Post-download failed: #{inspect(reason)}")
        ResultBuilder.download_error(source_video_id, reason)
    end
  end

  defp upload_to_s3(local_path, s3_key) do
    Logger.info("DownloadWorker: Uploading to S3: #{s3_key}")

    S3.upload_file_with_progress(local_path, s3_key,
      operation_name: "Download",
      storage_class: "STANDARD"
    )
  end

  defp cache_locally(s3_key, local_path) do
    case TempCache.put(s3_key, local_path) do
      {:ok, _} -> Logger.info("DownloadWorker: Cached for pipeline chaining")
      {:error, reason} -> Logger.warning("DownloadWorker: Cache failed: #{inspect(reason)}")
    end
  end

  defp save_metadata(source_video_id, result, s3_key) do
    metadata = %{
      filepath: s3_key,
      duration_seconds: result.duration_seconds,
      fps: result.fps,
      width: result.width,
      height: result.height,
      metadata: result.metadata
    }

    Core.complete_downloading(source_video_id, metadata)
  end

  defp build_result(source_video_id, updated_video, result) do
    download_result =
      ResultBuilder.download_success(source_video_id, updated_video.filepath, %{
        title: updated_video.title,
        duration_seconds: updated_video.duration_seconds,
        file_size_bytes: result.file_size_bytes,
        format_info:
          %{
            width: result.width,
            height: result.height,
            fps: result.fps
          }
          |> reject_nil_values(),
        quality_metrics:
          %{
            resolution: build_resolution_string(result.width, result.height),
            fps: result.fps
          }
          |> reject_nil_values(),
        metadata: result.metadata
      })

    ResultBuilder.log_result(__MODULE__, download_result)
    download_result
  end

  # -- Helpers -----------------------------------------------------------------

  defp ensure_downloading_state(source_video) do
    case source_video.ingest_state do
      :downloading ->
        Logger.info(
          "DownloadWorker: Video #{source_video.id} already in downloading state, resuming"
        )

        {:ok, source_video}

      _ ->
        Core.start_downloading(source_video.id)
    end
  end

  defp check_idempotency(%{ingest_state: state})
       when state in [:new, :downloading, :download_failed],
       do: :ok

  defp check_idempotency(_), do: {:error, :already_processed}

  defp generate_timestamp do
    DateTime.utc_now()
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
    |> String.replace(~r/[-: ]/, fn
      " " -> "_"
      _ -> ""
    end)
  end

  defp build_resolution_string(nil, _), do: nil
  defp build_resolution_string(_, nil), do: nil
  defp build_resolution_string(w, h), do: "#{w}x#{h}"

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
