defmodule Frontend.Workers.ArchiveWorker do
  use Oban.Worker, queue: :background_jobs

  alias Frontend.Clips
  alias Frontend.PythonRunner

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id}}) do
    try do
      clip = Clips.get_clip!(clip_id)
      handle_archiving(clip)
    rescue
      _e in Ecto.NoResultsError ->
        # Clip was likely deleted before the job ran, which is fine.
        :ok
    end
  end

  # Idempotency check: if the clip is already archived or failed, we're done.
  defp handle_archiving(%{ingest_state: "archived"}), do: :ok
  defp handle_archiving(%{ingest_state: "archive_failed"}), do: :ok

  defp handle_archiving(clip) do
    case PythonRunner.run("archive", %{clip_id: clip.id}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # The python script should set the error state, but we return an
        # error here so the Oban job is marked as failed.
        {:error, "Archive script failed: #{inspect(reason)}"}
    end
  end
end
