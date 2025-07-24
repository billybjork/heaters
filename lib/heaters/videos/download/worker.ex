defmodule Heaters.Videos.Download.Worker do
  use Heaters.Infrastructure.Orchestration.WorkerBehavior,
    queue: :media_processing,
    # 30 minutes, prevent duplicate jobs for same video
    unique: [period: 1800, fields: [:args]]

  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Infrastructure.PyRunner
  alias Heaters.Videos.Download
  alias Heaters.Infrastructure.Orchestration.WorkerBehavior
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

      # Python task constructs its own S3 path based on video title
      py_args = %{
        source_video_id: updated_video.id,
        input_source: updated_video.original_url
      }

      case PyRunner.run("download", py_args, timeout: :timer.minutes(20)) do
        {:ok, result} ->
          Logger.info(
            "DownloadWorker: PyRunner succeeded for source_video_id: #{source_video_id}, result: #{inspect(result)}"
          )

          # Elixir handles the state transition and metadata update
          # Convert string keys to atom keys for the metadata (recursively)
          metadata = convert_keys_to_atoms(result)

          case Download.complete_downloading(source_video_id, metadata) do
            {:ok, _updated_video} ->
              Logger.info(
                "DownloadWorker: Successfully completed download for source_video_id: #{source_video_id}"
              )

              # Pipeline will automatically pick up videos in 'downloaded' state for splicing
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

          case Download.mark_failed(updated_video, "download_failed", reason) do
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
        Download.start_downloading(source_video.id)
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
end
