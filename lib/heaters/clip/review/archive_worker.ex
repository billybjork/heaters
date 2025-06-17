defmodule Heaters.Clip.Review.ArchiveWorker do
  use Oban.Worker, queue: :background_jobs

  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Repo
  alias Heaters.Infrastructure.S3
  alias Ecto.Multi

  require Logger

  # Dialyzer cannot statically verify S3 operations due to external system dependencies
  @dialyzer {:nowarn_function, [perform: 1, archive_in_database: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id}}) do
    with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip) do
      # 1. Delete files from S3 using Elixir S3 context
      case S3.delete_clip_and_artifacts(clip) do
        {:ok, deleted_count} ->
          Logger.info("ArchiveWorker: Successfully deleted #{deleted_count} S3 objects for clip #{clip_id}")
          # 2. If S3 deletion is successful, perform all DB changes in one transaction
          archive_in_database(clip)

        {:error, reason} ->
          # If S3 deletion fails, update the clip with an error and let Oban retry.
          Logger.error("ArchiveWorker: S3 deletion failed for clip #{clip_id}: #{inspect(reason)}")
          ClipQueries.update_clip(clip, %{
            ingest_state: "archive_failed",
            last_error: "S3 Deletion Failed: #{inspect(reason)}"
          })

          {:error, reason}
      end
    else
      # Handle cases where the clip is not found or already archived.
      # Clip doesn't exist, work is done.
      {:error, :not_found} -> :ok
      # Already archived, work is done.
      {:error, :already_processed} -> :ok
      # Propagate other errors.
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_idempotency(clip) do
    if clip.ingest_state == "archived" do
      {:error, :already_archived}
    else
      :ok
    end
  end

  defp archive_in_database(clip) do
    case Multi.new()
         |> Multi.delete_all(:delete_artifacts, Ecto.assoc(clip, :clip_artifacts))
         |> Multi.update(:archive_clip, ClipQueries.change_clip(clip, %{ingest_state: "archived"}))
         |> Repo.transaction() do
      {:ok, _results} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end
