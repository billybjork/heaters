defmodule Heaters.Clip.Review.SpriteWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Clip.Review
  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Infrastructure.PyRunner
  require Logger

  @complete_states ["pending_review", "sprite_failed", "embedded", "review_approved", "review_archived"]

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [perform: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id}}) do
    Logger.info("SpriteWorker: Starting sprite generation for clip_id: #{clip_id}")

    with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip),
         {:ok, updated_clip} <- Review.start_sprite_generation(clip_id) do

      Logger.info("SpriteWorker: Running PyRunner for clip_id: #{clip_id}")

      # Python task receives explicit S3 paths and processing parameters
      py_args = %{
        clip_id: updated_clip.id,
        input_s3_path: updated_clip.clip_filepath,
        output_s3_prefix: Review.build_sprite_prefix(updated_clip),
        overwrite: false
      }

      case PyRunner.run("sprite", py_args) do
        {:ok, result} ->
          Logger.info("SpriteWorker: PyRunner succeeded for clip_id: #{clip_id}")

          # Use the Review context to process the success and transition to pending_review
          case Review.process_sprite_success(updated_clip, result) do
            {:ok, _final_clip} ->
              Logger.info("SpriteWorker: Clip #{clip_id} transitioned to pending_review state")
              :ok

            {:error, reason} ->
              Logger.error("SpriteWorker: Failed to process sprite success: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("SpriteWorker: PyRunner failed for clip_id: #{clip_id}, reason: #{inspect(reason)}")

          # Use the Review context to mark as failed
          case Review.mark_sprite_failed(updated_clip.id, reason) do
            {:ok, _} -> {:error, reason}
            {:error, db_error} ->
              Logger.error("SpriteWorker: Failed to mark clip as failed: #{inspect(db_error)}")
              {:error, reason}
          end
      end
    else
      {:error, :not_found} ->
        Logger.warning("SpriteWorker: Clip #{clip_id} not found, likely deleted")
        :ok

      {:error, :already_processed} ->
        Logger.info("SpriteWorker: Clip #{clip_id} already processed, skipping")
        :ok

      {:error, reason} ->
        Logger.error("SpriteWorker: Error in workflow for clip #{clip_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Idempotency check: Skip processing if already done or has sprite artifacts
  defp check_idempotency(%{ingest_state: state}) when state in @complete_states do
    {:error, :already_processed}
  end

  defp check_idempotency(%{clip_artifacts: artifacts} = _clip) do
    has_sprite? = Enum.any?(artifacts, &(&1.artifact_type == "sprite_sheet"))

    if has_sprite? do
      {:error, :already_processed}
    else
      :ok
    end
  end

  defp check_idempotency(%{ingest_state: "spliced"}), do: :ok
  defp check_idempotency(%{ingest_state: "sprite_failed"}), do: :ok
  defp check_idempotency(%{ingest_state: state}) do
    Logger.warning("SpriteWorker: Unexpected clip state '#{state}' for sprite generation")
    {:error, :invalid_state}
  end
end
