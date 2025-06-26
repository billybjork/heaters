defmodule Heaters.Workers.Clips.KeyframeWorker do
  use Heaters.Workers.GenericWorker, queue: :media_processing

  alias Heaters.Clips.Transform.Keyframe
  alias Heaters.Clips.Queries, as: ClipQueries
  require Logger

  @complete_states ["keyframed", "keyframe_failed", "embedded", "review_approved", "review_archived"]

  @impl Heaters.Workers.GenericWorker
  def handle(%{"clip_id" => clip_id} = args) do
    strategy = Map.get(args, "strategy", "multi")
    Logger.info("KeyframeWorker: Starting keyframe extraction for clip_id: #{clip_id}, strategy: #{strategy}")

    with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip) do

      case Keyframe.run_keyframe_extraction(clip_id, strategy) do
        {:ok, _updated_clip} ->
          Logger.info("KeyframeWorker: Clip #{clip_id} keyframing completed successfully")
          :ok

        {:error, reason} ->
          Logger.error("KeyframeWorker: Keyframe extraction failed for clip #{clip_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_found} ->
        Logger.warning("KeyframeWorker: Clip #{clip_id} not found, likely deleted")
        :ok

      {:error, :already_processed} ->
        Logger.info("KeyframeWorker: Clip #{clip_id} already processed, skipping")
        :ok

      {:error, reason} ->
        Logger.error("KeyframeWorker: Error in workflow for clip #{clip_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Idempotency check: Skip processing if already done or has keyframe artifacts
  defp check_idempotency(%{ingest_state: state}) when state in @complete_states do
    {:error, :already_processed}
  end

  defp check_idempotency(%{clip_artifacts: artifacts} = _clip) do
    has_keyframes? = Enum.any?(artifacts, &(&1.artifact_type == "keyframe"))

    if has_keyframes? do
      {:error, :already_processed}
    else
      :ok
    end
  end

  defp check_idempotency(%{ingest_state: "review_approved"}), do: :ok
  defp check_idempotency(%{ingest_state: "keyframe_failed"}), do: :ok
  defp check_idempotency(%{ingest_state: state}) do
    Logger.warning("KeyframeWorker: Unexpected clip state '#{state}' for keyframe extraction")
    {:error, :invalid_state}
  end
end
