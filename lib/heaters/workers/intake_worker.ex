defmodule Heaters.Workers.IntakeWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Clips
  alias Heaters.PythonRunner
  require Logger

  # Dialyzer cannot statically verify PythonRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, perform: 1}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_video_id" => source_video_id}}) do
    Logger.info("IntakeWorker: Starting intake for source_video_id: #{source_video_id}")

    # Use a `with` statement for a clean, chained workflow
    with {:ok, source_video} <- Clips.get_source_video(source_video_id),
         :ok <- check_idempotency(source_video) do
      Logger.info(
        "IntakeWorker: Running PythonRunner for source_video_id: #{source_video_id}, URL: #{source_video.original_url}"
      )

      # The PythonRunner now handles all environment config automatically.
      case PythonRunner.run(
             "intake",
             %{
               source_video_id: source_video.id,
               input_source: source_video.original_url
             },
             timeout: :timer.minutes(20)
           ) do
        {:ok, result} ->
          Logger.info(
            "IntakeWorker: PythonRunner succeeded for source_video_id: #{source_video_id}, result: #{inspect(result)}"
          )

          # On success, enqueue the NEXT worker in the chain.
          case Oban.insert(Heaters.Workers.SpliceWorker.new(%{source_video_id: source_video.id})) do
            {:ok, _job} -> :ok
            {:error, reason} -> {:error, "Failed to enqueue splice worker: #{inspect(reason)}"}
          end

        {:error, reason} ->
          # If the python script fails, we record the error and let Oban retry.
          Logger.error(
            "IntakeWorker: PythonRunner failed for source_video_id: #{source_video_id}, reason: #{inspect(reason)}"
          )

          error_message = inspect(reason)

          Clips.update_source_video(source_video, %{
            ingest_state: "download_failed",
            last_error: error_message
          })

          {:error, reason}
      end
    else
      # Handles errors from the `with` statement (e.g., video not found or already processed)
      {:error, :already_processed} ->
        Logger.info(
          "IntakeWorker: source_video_id #{source_video_id} already processed, skipping"
        )

        # Gracefully exit, not an error.
        :ok

      {:error, reason} ->
        Logger.error(
          "IntakeWorker: Error getting source video #{source_video_id}: #{inspect(reason)}"
        )

        # Propagate other errors for Oban to retry
        {:error, reason}
    end
  end

  # Idempotency Check: Ensures we don't re-process completed work.
  defp check_idempotency(%{ingest_state: "new"}), do: :ok
  defp check_idempotency(%{ingest_state: "download_failed"}), do: :ok
  defp check_idempotency(_), do: {:error, :already_processed}
end
