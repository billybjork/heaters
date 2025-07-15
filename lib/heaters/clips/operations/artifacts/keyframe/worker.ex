defmodule Heaters.Clips.Operations.Artifacts.Keyframe.Worker do
  use Heaters.Infrastructure.Orchestration.WorkerBehavior,
    queue: :media_processing,
    # 15 minutes, prevent duplicate keyframe jobs
    unique: [period: 900, fields: [:args]]

  alias Heaters.Clips.Operations.Artifacts.Keyframe
  alias Heaters.Clips.Operations.Shared.Types
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Infrastructure.Orchestration.WorkerBehavior

  @complete_states [
    "keyframed",
    "keyframe_failed",
    "embedded",
    "review_archived"
  ]

  @impl WorkerBehavior
  def handle_work(%{"clip_id" => clip_id} = args) do
    strategy = Map.get(args, "strategy", "multi")

    Logger.info(
      "KeyframeWorker: Starting keyframe extraction for clip_id: #{clip_id}, strategy: #{strategy}"
    )

    with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip) do
      case Keyframe.run_keyframe_extraction(clip_id, strategy) do
        {:ok, %Types.KeyframeResult{status: "success", keyframe_count: count}} ->
          Logger.info(
            "KeyframeWorker: Clip #{clip_id} keyframing completed successfully with #{count} keyframes"
          )

          :ok

        {:ok, %Types.KeyframeResult{status: status}} ->
          Logger.error("KeyframeWorker: Keyframe extraction failed with status: #{status}")
          {:error, "Unexpected keyframe result status: #{status}"}

        {:error, reason} ->
          Logger.error(
            "KeyframeWorker: Keyframe extraction failed for clip #{clip_id}: #{inspect(reason)}"
          )

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
         :ok <- WorkerBehavior.check_artifact_exists(clip, "keyframe"),
         :ok <- check_keyframe_specific_states(clip) do
      :ok
    end
  end

  defp check_keyframe_specific_states(%{ingest_state: "review_approved"}), do: :ok
  defp check_keyframe_specific_states(%{ingest_state: "keyframe_failed"}), do: :ok

  defp check_keyframe_specific_states(%{ingest_state: state}) do
    Logger.warning("KeyframeWorker: Unexpected clip state '#{state}' for keyframe extraction")
    {:error, :invalid_state}
  end
end
