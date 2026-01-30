defmodule Heaters.Storage.Archive.Worker do
  @moduledoc """
  Worker for archiving clips by deleting their S3 files and updating database state.
  """

  use Heaters.Pipeline.WorkerBehavior,
    queue: :background_jobs,
    # 5 minutes, prevent duplicate archive jobs
    unique: [period: 300, fields: [:args]]

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Heaters.Media.Clip
  alias Heaters.Media.Clips
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Processing.Support.ResultBuilder
  alias Heaters.Repo
  alias Heaters.Storage.S3.Adapter
  require Logger

  # Dialyzer cannot statically verify S3 operations due to external system dependencies
  @dialyzer {:nowarn_function, [handle_work: 1, archive_in_database: 1]}

  @impl WorkerBehavior
  def handle_work(%{"clip_id" => clip_id}) do
    with {:ok, clip} <- Clips.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip),
         {:ok, deleted_count} <- delete_s3_artifacts(clip, clip_id),
         :ok <- archive_in_database(clip) do
      build_archive_success_result(clip_id, deleted_count)
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Clip", clip_id)

      {:error, :already_processed} ->
        build_already_archived_result(clip_id)

      {:error, {:s3_failed, clip, reason}} ->
        handle_s3_failure(clip, clip_id, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_s3_artifacts(clip, clip_id) do
    case Adapter.delete_clip_and_artifacts(clip) do
      {:ok, deleted_count} ->
        Logger.info(
          "ArchiveWorker: Successfully deleted #{deleted_count} S3 objects for clip #{clip_id}"
        )

        {:ok, deleted_count}

      {:error, reason} ->
        {:error, {:s3_failed, clip, reason}}
    end
  end

  defp build_archive_success_result(clip_id, deleted_count) do
    archive_result =
      ResultBuilder.archive_success(clip_id, deleted_count, %{
        s3_operations: %{
          objects_deleted: deleted_count,
          operation_type: "delete_clip_and_artifacts"
        }
      })

    ResultBuilder.log_result(__MODULE__, archive_result)
    archive_result
  end

  defp build_already_archived_result(clip_id) do
    Logger.info("ArchiveWorker: Clip #{clip_id} already archived, skipping")

    archive_result = ResultBuilder.archive_success(clip_id, 0, %{already_processed: true})
    ResultBuilder.log_result(__MODULE__, archive_result)
    archive_result
  end

  defp handle_s3_failure(clip, clip_id, reason) do
    Logger.error("ArchiveWorker: S3 deletion failed for clip #{clip_id}: #{inspect(reason)}")

    Clips.update_clip(clip, %{
      ingest_state: "archive_failed",
      last_error: "S3 Deletion Failed: #{inspect(reason)}"
    })

    {:error, reason}
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
