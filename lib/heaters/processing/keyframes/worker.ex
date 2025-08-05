defmodule Heaters.Processing.Keyframes.Worker do
  use Heaters.Pipeline.WorkerBehavior,
    queue: :media_processing,
    # 15 minutes, prevent duplicate keyframe jobs
    unique: [period: 900, fields: [:args]]

  # TODO: Restore aliases when keyframes functionality is restored
  # alias Heaters.Processing.Keyframes.Core
  # alias Heaters.Media.Support.Types
  alias Heaters.Media.Clips
  alias Heaters.Pipeline.WorkerBehavior

  @complete_states [
    :keyframed,
    :keyframe_failed,
    :embedded,
    :review_archived
  ]

  @impl WorkerBehavior
  def handle_work(%{"clip_id" => clip_id} = args) do
    _strategy = Map.get(args, "strategy", :multi)

    # TODO: Keyframes functionality needs to be rewritten for cuts-based architecture
    # For now, skip keyframe processing to avoid blocking the pipeline
    Logger.info(
      "KeyframeWorker: Keyframes processing temporarily disabled - skipping clip #{clip_id}"
    )

    with {:ok, clip} <- Clips.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip) do
      # Mark clip as keyframed without actually processing keyframes
      case Clips.update_state(clip, :keyframed) do
        {:ok, _updated_clip} ->
          Logger.info(
            "KeyframeWorker: Marked clip #{clip_id} as keyframed (no actual processing)"
          )

          :ok

        {:error, reason} ->
          Logger.error("KeyframeWorker: Failed to update clip state: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Clip", clip_id)

      {:error, :already_processed} ->
        WorkerBehavior.handle_already_processed("Clip", clip_id)

      {:error, reason} ->
        Logger.error("KeyframeWorker: Error in workflow for clip #{clip_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Idempotency check: Skip processing if already done or has keyframe artifacts
  defp check_idempotency(clip) do
    with :ok <- WorkerBehavior.check_complete_states(clip, @complete_states),
         :ok <- check_artifact_exists_unless_retry(clip),
         :ok <- check_keyframe_specific_states(clip) do
      :ok
    end
  end

  # For retry states, skip artifact check to allow reprocessing
  defp check_artifact_exists_unless_retry(%{ingest_state: :keyframe_failed}), do: :ok

  defp check_artifact_exists_unless_retry(clip),
    do: WorkerBehavior.check_artifact_exists(clip, "keyframe")

  defp check_keyframe_specific_states(%{ingest_state: :review_approved}), do: :ok
  defp check_keyframe_specific_states(%{ingest_state: :keyframe_failed}), do: :ok

  defp check_keyframe_specific_states(%{ingest_state: state}) do
    Logger.warning("KeyframeWorker: Unexpected clip state '#{state}' for keyframe extraction")
    {:error, :invalid_state}
  end
end
