defmodule Heaters.Workers.Clip.KeyframeWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Clip.Transform
  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Infrastructure.PyRunner
  require Logger

  @complete_states ["keyframed", "keyframe_failed", "embedded", "review_approved", "review_archived"]

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [perform: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id}}) do
    Logger.info("KeyframeWorker: Starting keyframe extraction for clip_id: #{clip_id}")

    with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip),
         {:ok, updated_clip} <- Transform.start_keyframing(clip_id) do

      Logger.info("KeyframeWorker: Running PyRunner for clip_id: #{clip_id}")

      # Python task receives explicit S3 paths and keyframe parameters
      py_args = %{
        clip_id: updated_clip.id,
        input_s3_path: updated_clip.clip_filepath,
        output_s3_prefix: Transform.build_keyframe_prefix(updated_clip),
        keyframe_params: %{
          strategy: "uniform",
          count: 5
        }
      }

      case PyRunner.run("keyframe", py_args) do
        {:ok, result} ->
          Logger.info("KeyframeWorker: PyRunner succeeded for clip_id: #{clip_id}")

          # Use the Transform context to process the success and create artifacts
          case Transform.process_keyframe_success(updated_clip, result) do
            {:ok, _final_clip} ->
              Logger.info("KeyframeWorker: Clip #{clip_id} keyframing completed successfully")
              :ok

            {:error, reason} ->
              Logger.error("KeyframeWorker: Failed to process keyframe success: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("KeyframeWorker: PyRunner failed for clip_id: #{clip_id}, reason: #{inspect(reason)}")

          # Use the Transform context to mark as failed
          case Transform.mark_failed(updated_clip.id, "keyframe_failed", reason) do
            {:ok, _} -> {:error, reason}
            {:error, db_error} ->
              Logger.error("KeyframeWorker: Failed to mark clip as failed: #{inspect(db_error)}")
              {:error, reason}
          end
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

  defp check_idempotency(%{ingest_state: "pending_review"}), do: :ok
  defp check_idempotency(%{ingest_state: "keyframe_failed"}), do: :ok
  defp check_idempotency(%{ingest_state: state}) do
    Logger.warning("KeyframeWorker: Unexpected clip state '#{state}' for keyframe extraction")
    {:error, :invalid_state}
  end
end
