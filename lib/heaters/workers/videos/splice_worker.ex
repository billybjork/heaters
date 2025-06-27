defmodule Heaters.Workers.Videos.SpliceWorker do
  use Heaters.Workers.GenericWorker, queue: :media_processing

  alias Heaters.Videos.Ingest
  alias Heaters.Videos.SourceVideo
  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Infrastructure.PyRunner
  alias Heaters.Workers.Clips.SpriteWorker
  require Logger

  @splicing_complete_states ["spliced", "splicing_failed"]

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [handle: 1, handle_splicing: 1]}

  @impl Heaters.Workers.GenericWorker
  def handle(%{"source_video_id" => source_video_id}) do
    Logger.info("SpliceWorker: Starting splice for source_video_id: #{source_video_id}")

    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      handle_splicing(source_video)
    else
      {:error, :not_found} ->
        Logger.warning("SpliceWorker: Source video #{source_video_id} not found")
        :ok
    end
  end

  defp handle_splicing(%SourceVideo{ingest_state: state} = source_video)
       when state in @splicing_complete_states do
    Logger.info(
      "SpliceWorker: Source video #{source_video.id} already in state '#{state}', skipping"
    )

    :ok
  end

  defp handle_splicing(%SourceVideo{ingest_state: "splicing"} = source_video) do
    Logger.info(
      "SpliceWorker: Source video #{source_video.id} already in 'splicing' state, proceeding with Python task"
    )

    run_python_splice_task(source_video)
  end

  defp handle_splicing(source_video) do
    # Use new state management pattern
    case Ingest.start_splicing(source_video.id) do
      {:ok, updated_video} ->
        run_python_splice_task(updated_video)

      {:error, reason} ->
        Logger.error("SpliceWorker: Failed to transition to splicing state: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_python_splice_task(source_video) do
    Logger.info("SpliceWorker: Running PyRunner for source_video_id: #{source_video.id}")

    # Python task receives explicit S3 paths and detection parameters
    py_args = %{
      source_video_id: source_video.id,
      input_s3_path: source_video.filepath,
      output_s3_prefix: Ingest.build_s3_prefix(source_video),
      detection_params: %{threshold: 0.3}
    }

    case PyRunner.run("splice", py_args) do
      {:ok, %{"result" => %{"clips" => clips_data}}} when is_list(clips_data) ->
        Logger.info(
          "SpliceWorker: Successfully received #{length(clips_data)} clips from Python"
        )

        # Validate clips data before processing
        case Ingest.validate_clips_data(clips_data) do
          :ok ->
            # Create clips and update source video state in Elixir
            case Ingest.create_clips_from_splice(source_video.id, clips_data) do
              {:ok, clips} ->
                case Ingest.complete_splicing(source_video.id) do
                  {:ok, _final_video} ->
                    # Store clips for enqueue_next/1 to use
                    Process.put(:clips, clips)
                    :ok

                  {:error, reason} ->
                    Logger.error(
                      "SpliceWorker: Failed to mark splicing complete: #{inspect(reason)}"
                    )

                    {:error, reason}
                end

              {:error, reason} ->
                Logger.error("SpliceWorker: Failed to create clips: #{inspect(reason)}")
                mark_splicing_failed(source_video, reason)
            end

          {:error, validation_error} ->
            Logger.error("SpliceWorker: Invalid clips data: #{validation_error}")
            mark_splicing_failed(source_video, validation_error)
        end

      {:ok, unexpected_result} ->
        error_message =
          "Splice script returned unexpected result: #{inspect(unexpected_result)}"

        Logger.error("SpliceWorker: #{error_message}")
        mark_splicing_failed(source_video, error_message)

      {:error, reason} ->
        error_message = "Splice script failed: #{inspect(reason)}"
        Logger.error("SpliceWorker: #{error_message}")
        mark_splicing_failed(source_video, reason)
    end
  end

  defp mark_splicing_failed(source_video, reason) do
    case Ingest.mark_failed(source_video, "splicing_failed", reason) do
      {:ok, _} ->
        {:error, reason}

      {:error, db_error} ->
        Logger.error("SpliceWorker: Failed to mark video as failed: #{inspect(db_error)}")
        {:error, reason}
    end
  end

  @impl Heaters.Workers.GenericWorker
  def enqueue_next(_args) do
    case Process.get(:clips) do
      clips when is_list(clips) ->
        # Enqueue sprite workers for all created clips (for review preparation)
        jobs =
          clips
          |> Enum.map(fn clip ->
            SpriteWorker.new(%{clip_id: clip.id})
          end)

        try do
          case Oban.insert_all(jobs) do
            inserted_jobs when is_list(inserted_jobs) and length(inserted_jobs) > 0 ->
              Logger.info("SpliceWorker: Enqueued #{length(inserted_jobs)} sprite workers")
              :ok

            [] ->
              Logger.error("SpliceWorker: Failed to enqueue sprite workers - no jobs inserted")
              {:error, "No sprite jobs were enqueued"}

            %Ecto.Multi{} = multi ->
              Logger.error(
                "SpliceWorker: Oban.insert_all returned Multi instead of jobs: #{inspect(multi)}"
              )

              {:error, "Unexpected Multi result from Oban.insert_all"}
          end
        rescue
          error ->
            error_message = "Failed to enqueue sprite workers: #{Exception.message(error)}"
            Logger.error("SpliceWorker: #{error_message}")
            {:error, error_message}
        end

      _ ->
        {:error, "No clips found to enqueue sprite workers"}
    end
  end
end
