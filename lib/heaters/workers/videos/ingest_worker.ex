defmodule Heaters.Workers.Videos.IngestWorker do
  use Heaters.Workers.GenericWorker, queue: :media_processing

  alias Heaters.Videos.Ingest
  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Infrastructure.PyRunner
  require Logger

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, handle: 1}

  @impl Heaters.Workers.GenericWorker
  def handle(%{"source_video_id" => source_video_id}) do
    Logger.info("IngestWorker: Starting ingest for source_video_id: #{source_video_id}")

    # Use new state management pattern
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id),
         :ok <- check_idempotency(source_video),
         {:ok, updated_video} <- Ingest.start_downloading(source_video_id) do
      Logger.info(
        "IngestWorker: Running PyRunner for source_video_id: #{source_video_id}, URL: #{updated_video.original_url}"
      )

      # Python task now receives explicit S3 output prefix and returns data instead of managing state
      py_args = %{
        source_video_id: updated_video.id,
        input_source: updated_video.original_url,
        output_s3_prefix: Ingest.build_s3_prefix(updated_video),
        re_encode_for_qt: true
      }

      case PyRunner.run("ingest", py_args, timeout: :timer.minutes(20)) do
        {:ok, result} ->
          Logger.info(
            "IngestWorker: PyRunner succeeded for source_video_id: #{source_video_id}, result: #{inspect(result)}"
          )

          # Elixir handles the state transition and metadata update
          case Ingest.complete_downloading(source_video_id, result) do
            {:ok, _updated_video} ->
              # Store the video ID for enqueue_next/1 to use
              Process.put(:source_video_id, updated_video.id)
              :ok

            {:error, reason} ->
              Logger.error("IngestWorker: Failed to update video metadata: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          # If the python script fails, we use the new state management to record the error
          Logger.error(
            "IngestWorker: PyRunner failed for source_video_id: #{source_video_id}, reason: #{inspect(reason)}"
          )

          case Ingest.mark_failed(updated_video, "ingestion_failed", reason) do
            {:ok, _} ->
              {:error, reason}

            {:error, db_error} ->
              Logger.error("IngestWorker: Failed to mark video as failed: #{inspect(db_error)}")
              {:error, reason}
          end
      end
    else
      # Handles errors from the `with` statement (e.g., video not found or already processed)
      {:error, :already_processed} ->
        Logger.info(
          "IngestWorker: source_video_id #{source_video_id} already processed, skipping"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "IngestWorker: Error in workflow for source video #{source_video_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @impl Heaters.Workers.GenericWorker
  def enqueue_next(_args) do
    case Process.get(:source_video_id) do
      source_video_id when is_integer(source_video_id) ->
        # Enqueue the next worker in the chain
        case Oban.insert(
               Heaters.Workers.Videos.SpliceWorker.new(%{source_video_id: source_video_id})
             ) do
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, "Failed to enqueue splice worker: #{inspect(reason)}"}
        end

      _ ->
        {:error, "No source_video_id found to enqueue splice worker"}
    end
  end

  # Idempotency Check: Ensures we don't re-process completed work.
  defp check_idempotency(%{ingest_state: "new"}), do: :ok
  defp check_idempotency(%{ingest_state: "ingestion_failed"}), do: :ok
  defp check_idempotency(_), do: {:error, :already_processed}
end
