defmodule Heaters.Workers.Videos.IngestWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Videos.Ingest
  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Infrastructure.PyRunner
  require Logger

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [perform: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    module_name = __MODULE__ |> Module.split() |> List.last()
    Logger.info("#{module_name}: Starting job with args: #{inspect(args)}")

    start_time = System.monotonic_time()

    try do
      case handle_ingest_work(args) do
        :ok ->
          duration_ms =
            System.convert_time_unit(
              System.monotonic_time() - start_time,
              :native,
              :millisecond
            )

          Logger.info("#{module_name}: Job completed successfully in #{duration_ms}ms")
          :ok

        {:error, reason} ->
          Logger.error("#{module_name}: Job failed: #{inspect(reason)}")
          {:error, reason}

        other ->
          Logger.error("#{module_name}: Job returned unexpected result: #{inspect(other)}")
          {:error, "Unexpected return value: #{inspect(other)}"}
      end
    rescue
      error ->
        Logger.error("#{module_name}: Job crashed with exception: #{Exception.message(error)}")

        Logger.error(
          "#{module_name}: Exception details: #{Exception.format(:error, error, __STACKTRACE__)}"
        )

        {:error, Exception.message(error)}
    catch
      :exit, reason ->
        Logger.error("#{module_name}: Job exited with reason: #{inspect(reason)}")
        {:error, "Process exit: #{inspect(reason)}"}

      :throw, value ->
        Logger.error("#{module_name}: Job threw value: #{inspect(value)}")
        {:error, "Thrown value: #{inspect(value)}"}
    end
  end

  defp handle_ingest_work(%{"source_video_id" => source_video_id}) do
    Logger.info("IngestWorker: Starting download for source_video_id: #{source_video_id}")

    # Use new state management pattern
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id),
         :ok <- check_idempotency(source_video),
         {:ok, updated_video} <- Ingest.start_downloading(source_video_id) do
      Logger.info(
        "IngestWorker: Running PyRunner for source_video_id: #{source_video_id}, URL: #{updated_video.original_url}"
      )

      # Python task constructs its own S3 path based on video title
      py_args = %{
        source_video_id: updated_video.id,
        input_source: updated_video.original_url,
        re_encode_for_qt: true
      }

      case PyRunner.run("ingest", py_args, timeout: :timer.minutes(20)) do
        {:ok, result} ->
          Logger.info(
            "IngestWorker: PyRunner succeeded for source_video_id: #{source_video_id}, result: #{inspect(result)}"
          )

          # Elixir handles the state transition and metadata update
          # Convert string keys to atom keys for the metadata (recursively)
          metadata = convert_keys_to_atoms(result)

          case Ingest.complete_downloading(source_video_id, metadata) do
            {:ok, _updated_video} ->
              Logger.info(
                "IngestWorker: Successfully completed download for source_video_id: #{source_video_id}"
              )

              # Pipeline will automatically pick up videos in 'downloaded' state for splicing
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

          case Ingest.mark_failed(updated_video, "download_failed", reason) do
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

        # Return error to prevent any further processing
        {:error, :already_processed}

      {:error, reason} ->
        Logger.error(
          "IngestWorker: Error in workflow for source video #{source_video_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Idempotency Check: Ensures we don't re-process completed work.
  defp check_idempotency(%{ingest_state: "new"}), do: :ok
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
