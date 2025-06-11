defmodule Frontend.Workers.IntakeWorker do
  use Oban.Worker, queue: :ingest, max_attempts: 3

  alias Frontend.Clips
  alias Frontend.PythonRunner

  # Suppress Dialyzer warnings about pattern matching with PythonRunner
  @dialyzer {:nowarn_function, perform: 1}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_video_id" => source_video_id}}) do
    # Use a `with` statement for a clean, chained workflow
    with {:ok, source_video} <- Clips.get_source_video(source_video_id),
         :ok <- check_idempotency(source_video) do
      # The PythonRunner now handles all environment config automatically.
      case PythonRunner.run("intake", %{
        source_video_id: source_video.id,
        input_source: source_video.original_url
      }, timeout: :timer.minutes(20)) do

        {:ok, _result} ->
          # On success, enqueue the NEXT worker in the chain.
          case Oban.insert(Frontend.Workers.SpliceWorker.new(%{source_video_id: source_video.id})) do
            {:ok, _job} -> :ok
            {:error, reason} -> {:error, "Failed to enqueue splice worker: #{inspect(reason)}"}
          end

        {:error, reason} ->
          # If the python script fails, we record the error and let Oban retry.
          Clips.update_source_video(source_video, %{ingest_state: "download_failed", last_error: inspect(reason)})
          {:error, reason}
      end
    else
      # Handles errors from the `with` statement (e.g., video not found or already processed)
      {:error, :already_processed} -> :ok # Gracefully exit, not an error.
      {:error, reason} -> {:error, reason} # Propagate other errors for Oban to retry
    end
  end

  # Idempotency Check: Ensures we don't re-process completed work.
  defp check_idempotency(%{ingest_state: "new"}), do: :ok
  defp check_idempotency(%{ingest_state: "download_failed"}), do: :ok
  defp check_idempotency(_), do: {:error, :already_processed}
end
