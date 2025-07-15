defmodule Heaters.Clips.Operations.Artifacts.Sprite.Worker do
  use Heaters.Infrastructure.Orchestration.WorkerBehavior,
    queue: :default,
    # 10 minutes, prevent duplicate sprite jobs
    unique: [period: 600, fields: [:args]]

  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Clips.Operations
  alias Heaters.Clips.Operations.Artifacts.Sprite
  alias Heaters.Infrastructure.Orchestration.WorkerBehavior
  require Logger

  @complete_states [
    "pending_review",
    "sprite_failed",
    "embedded",
    "review_approved",
    "review_archived"
  ]

  @impl WorkerBehavior
  def handle_work(%{"clip_id" => clip_id}) do
    Logger.info("SpriteWorker: Starting sprite generation for clip_id: #{clip_id}")

    with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip),
         {:ok, updated_clip} <- ensure_sprite_generating_state(clip_id, clip) do
      Logger.info("SpriteWorker: Running Elixir sprite generation for clip_id: #{clip_id}")

      # Use the native Elixir sprite generation module
      case Sprite.run_sprite(clip_id) do
        {:ok, result} ->
          Logger.info("SpriteWorker: Sprite generation succeeded for clip_id: #{clip_id}")

          # Use the Transform context to process the success and transition to pending_review
          case Operations.process_sprite_success(updated_clip, result) do
            {:ok, _final_clip} ->
              Logger.info("SpriteWorker: Clip #{clip_id} transitioned to pending_review state")
              :ok

            {:error, reason} ->
              Logger.error("SpriteWorker: Failed to process sprite success: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error(
            "SpriteWorker: Sprite generation failed for clip_id: #{clip_id}, reason: #{inspect(reason)}"
          )

          # Use the Transform context to mark as failed
          case Operations.mark_sprite_failed(updated_clip.id, reason) do
            {:ok, _} ->
              {:error, reason}

            {:error, db_error} ->
              Logger.error("SpriteWorker: Failed to mark clip as failed: #{inspect(db_error)}")
              {:error, reason}
          end
      end
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Clip", clip_id)

      {:error, :already_processed} ->
        WorkerBehavior.handle_already_processed("Clip", clip_id)

      {:error, reason} ->
        Logger.error("SpriteWorker: Error in workflow for clip #{clip_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Helper function to ensure clip is in generating_sprite state, handling resumable processing
  defp ensure_sprite_generating_state(clip_id, clip) do
    case clip.ingest_state do
      "generating_sprite" ->
        Logger.info("SpriteWorker: Clip #{clip_id} already in generating_sprite state, resuming")
        {:ok, clip}

      _ ->
        # Transition to generating_sprite state for other valid states
        Operations.start_sprite_generation(clip_id)
    end
  end

  # Idempotency check: Skip processing if already done or has sprite artifacts
  defp check_idempotency(clip) do
    with :ok <- WorkerBehavior.check_complete_states(clip, @complete_states),
         :ok <- check_sprite_specific_states(clip),
         :ok <- WorkerBehavior.check_artifact_exists(clip, "sprite_sheet") do
      :ok
    end
  end

  # Updated to support resumable processing
  defp check_sprite_specific_states(%{ingest_state: "generating_sprite"}),
    # Allow resuming interrupted sprite generation
    do: :ok

  defp check_sprite_specific_states(%{ingest_state: "spliced"}), do: :ok
  defp check_sprite_specific_states(%{ingest_state: "sprite_failed"}), do: :ok

  defp check_sprite_specific_states(%{ingest_state: state}) do
    Logger.warning("SpriteWorker: Unexpected clip state '#{state}' for sprite generation")
    {:error, :invalid_state}
  end
end
