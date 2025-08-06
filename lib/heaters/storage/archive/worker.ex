defmodule Heaters.Storage.Archive.Worker do
  use Heaters.Pipeline.WorkerBehavior,
    queue: :background_jobs,
    # 5 minutes, prevent duplicate archive jobs
    unique: [period: 300, fields: [:args]]

  import Ecto.Query, warn: false
  alias Heaters.Media.Clips
  alias Heaters.Repo
  alias Heaters.Storage.S3.Adapter
  alias Heaters.Media.Clip
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Processing.Support.ResultBuilder
  alias Ecto.Multi
  require Logger

  # Dialyzer cannot statically verify S3 operations due to external system dependencies
  @dialyzer {:nowarn_function, [handle_work: 1, archive_in_database: 1]}

  @impl WorkerBehavior
  def handle_work(%{"clip_id" => clip_id}) do
    with {:ok, clip} <- Clips.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip) do
      # 1. Delete files from S3 using S3Adapter for domain-specific operations
      case Adapter.delete_clip_and_artifacts(clip) do
        {:ok, deleted_count} ->
          Logger.info(
            "ArchiveWorker: Successfully deleted #{deleted_count} S3 objects for clip #{clip_id}"
          )

          # 2. If S3 deletion is successful, perform all DB changes in one transaction
          case archive_in_database(clip) do
            :ok ->
              # Build structured result with archival statistics
              archive_result =
                ResultBuilder.archive_success(clip_id, deleted_count, %{
                  s3_operations: %{
                    objects_deleted: deleted_count,
                    operation_type: "delete_clip_and_artifacts"
                  }
                })

              # Log structured result for observability
              ResultBuilder.log_result(__MODULE__, archive_result)
              archive_result

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          # If S3 deletion fails, update the clip with an error and let Oban retry.
          Logger.error(
            "ArchiveWorker: S3 deletion failed for clip #{clip_id}: #{inspect(reason)}"
          )

          Clips.update_clip(clip, %{
            ingest_state: "archive_failed",
            last_error: "S3 Deletion Failed: #{inspect(reason)}"
          })

          {:error, reason}
      end
    else
      # Handle cases where the clip is not found or already archived.
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Clip", clip_id)

      {:error, :already_processed} ->
        Logger.info("ArchiveWorker: Clip #{clip_id} already archived, skipping")

        # Return structured result for already processed clip
        archive_result =
          ResultBuilder.archive_success(clip_id, 0, %{
            already_processed: true
          })

        ResultBuilder.log_result(__MODULE__, archive_result)
        archive_result

      # Propagate other errors.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_idempotency(clip) do
    if clip.ingest_state == :archived do
      {:error, :already_processed}
    else
      :ok
    end
  end

  defp archive_in_database(clip) do
    Multi.new()
    |> Multi.update_all(
      :update_clip,
      from(c in Clip, where: c.id == ^clip.id),
      set: [ingest_state: :archived, action_committed_at: DateTime.utc_now()]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{update_clip: {1, _}}} ->
        Logger.info("ArchiveWorker: Successfully archived clip #{clip.id}")
        :ok

      {:ok, %{update_clip: {0, _}}} ->
        Logger.warning("ArchiveWorker: Clip #{clip.id} was not found during archiving")
        :ok

      {:error, operation, reason, _changes} ->
        Logger.error(
          "ArchiveWorker: Database transaction failed at #{operation}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
