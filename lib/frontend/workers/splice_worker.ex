defmodule Frontend.Workers.SpliceWorker do
  use Oban.Worker, queue: :media_processing

  alias Frontend.Clips
  alias Frontend.Clips.SourceVideo
  alias Frontend.PythonRunner
  alias Frontend.Workers.SpriteWorker

  @splicing_complete_states ["spliced", "splicing_failed"]

  # Suppress Dialyzer warnings about pattern matching with PythonRunner
  @dialyzer {:nowarn_function, [perform: 1, handle_splicing: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_video_id" => source_video_id}}) do
    with {:ok, source_video} <- Clips.get_source_video(source_video_id) do
      handle_splicing(source_video)
    else
      {:error, :not_found} ->
        # Video not found, nothing to do.
        :ok
    end
  end

  defp handle_splicing(%SourceVideo{ingest_state: state} = _source_video)
       when state in @splicing_complete_states do
    # Already spliced or failed, this is a success for the job.
    :ok
  end

  defp handle_splicing(source_video) do
    case PythonRunner.run("splice", %{source_video_id: source_video.id}) do
      {:ok, %{"result" => %{"clip_ids" => clip_ids}}} when is_list(clip_ids) ->
        jobs =
          Enum.map(clip_ids, fn clip_id ->
            SpriteWorker.new(%{clip_id: clip_id})
          end)

        try do
          _inserted_jobs = Oban.insert_all(jobs)
          :ok
        rescue
          error -> {:error, "Failed to enqueue sprite workers: #{Exception.message(error)}"}
        end

      {:ok, other} ->
        error_message =
          "Splice script for source video #{source_video.id} finished with unexpected payload: #{inspect(other)}"

        update_video_with_error(source_video, error_message)
        {:error, error_message}

      {:error, reason} ->
        error_message =
          "Splice script for source video #{source_video.id} failed: #{inspect(reason)}"

        update_video_with_error(source_video, error_message)
        {:error, error_message}
    end
  end

  defp update_video_with_error(source_video, error_message) do
    Clips.update_source_video(source_video, %{
      ingest_state: "splicing_failed",
      last_error: error_message
    })
  end
end
