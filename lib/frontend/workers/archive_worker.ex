defmodule Frontend.Workers.ArchiveWorker do
  use Oban.Worker, queue: :background_jobs, max_attempts: 3

  alias Frontend.Clips
  alias Frontend.Repo
  alias Frontend.PythonRunner
  alias Ecto.Multi

  # Suppress Dialyzer warnings about pattern matching with PythonRunner
  @dialyzer {:nowarn_function, [perform: 1, archive_in_database: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id}}) do
    with {:ok, clip} <- Clips.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip) do

      # 1. Consolidate all S3 keys to be deleted
      artifact_keys = Enum.map(clip.clip_artifacts, & &1.s3_key)
      all_keys = [clip.clip_filepath | artifact_keys] |> Enum.reject(&is_nil/1)

      # 2. Run the Python script to delete files from S3
      case PythonRunner.run("archive", %{s3_keys_to_delete: all_keys}) do
        {:ok, _result} ->
          # 3. If S3 deletion is successful, perform all DB changes in one transaction
          archive_in_database(clip)

        {:error, reason} ->
          # If Python script fails, update the clip with an error and let Oban retry.
          Clips.update_clip(clip, %{ingest_state: "archive_failed", last_error: "S3 Deletion Failed: #{inspect(reason)}"})
          {:error, reason}
      end
    else
      # Handle cases where the clip is not found or already archived.
      {:error, :not_found} -> :ok # Clip doesn't exist, work is done.
      {:error, :already_processed} -> :ok # Already archived, work is done.
      {:error, reason} -> {:error, reason} # Propagate other errors.
    end
  end

  defp check_idempotency(%{ingest_state: state}) when state in ["archived", "archive_failed"],
    do: {:error, :already_processed}
  defp check_idempotency(_clip),
    do: :ok

  defp archive_in_database(clip) do
    case Multi.new()
         |> Multi.delete_all(:delete_artifacts, Ecto.assoc(clip, :clip_artifacts))
         |> Multi.update(:archive_clip, Clips.change_clip(clip, %{ingest_state: "archived"}))
         |> Repo.transaction() do
      {:ok, _results} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end
