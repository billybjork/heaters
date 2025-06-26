defmodule Heaters.Workers.Clips.SpriteWorker do
  use Heaters.Workers.GenericWorker, queue: :media_processing

  alias Heaters.Clips.Transform
  alias Heaters.Clips.Transform.Sprite
  alias Heaters.Clips.Queries, as: ClipQueries
  require Logger

  @complete_states ["pending_review", "sprite_failed", "embedded", "review_approved", "review_archived"]

  @impl Heaters.Workers.GenericWorker
  def handle(%{"clip_id" => clip_id}) do
    Logger.info("SpriteWorker: Starting sprite generation for clip_id: #{clip_id}")

    with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip),
         {:ok, updated_clip} <- Transform.start_sprite_generation(clip_id) do

      Logger.info("SpriteWorker: Running Elixir sprite generation for clip_id: #{clip_id}")

      # Use the native Elixir sprite generation module
      case Sprite.run_sprite(clip_id) do
        {:ok, result} ->
          Logger.info("SpriteWorker: Sprite generation succeeded for clip_id: #{clip_id}")

          # Use the Transform context to process the success and transition to pending_review
          case Transform.process_sprite_success(updated_clip, result) do
            {:ok, _final_clip} ->
              Logger.info("SpriteWorker: Clip #{clip_id} transitioned to pending_review state")
              :ok

            {:error, reason} ->
              Logger.error("SpriteWorker: Failed to process sprite success: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("SpriteWorker: Sprite generation failed for clip_id: #{clip_id}, reason: #{inspect(reason)}")

          # Use the Transform context to mark as failed
          case Transform.mark_sprite_failed(updated_clip.id, reason) do
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
