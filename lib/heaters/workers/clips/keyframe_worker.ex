defmodule Heaters.Workers.Clips.KeyframeWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Clips.Operations.Artifacts.Keyframe
  alias Heaters.Clips.Operations.Shared.Types
  alias Heaters.Clips.Queries, as: ClipQueries
  require Logger

  @complete_states [
    "keyframed",
    "keyframe_failed",
    "embedded",
    "review_approved",
    "review_archived"
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    module_name = __MODULE__ |> Module.split() |> List.last()
    Logger.info("#{module_name}: Starting job with args: #{inspect(args)}")

    start_time = System.monotonic_time()

    try do
      case handle_keyframe_work(args) do
        :ok ->
          duration_ms =
            System.convert_time_unit(
              System.monotonic_time() - start_time,
              :native,
              :millisecond
            )

          Logger.info("#{module_name}: Job completed successfully in #{duration_ms}ms")
          :ok

        {:error, reason} ->
          Logger.error("#{module_name}: Job failed: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("#{module_name}: Job crashed with exception: #{Exception.message(error)}")

        Logger.error(
          "#{module_name}: Exception details: #{Exception.format(:error, error, __STACKTRACE__)}"
        )

        {:error, Exception.message(error)}
    catch
      :exit, reason ->
        Logger.error("#{module_name}: Job exited with reason: #{inspect(reason)}")
        {:error, "Process exit: #{inspect(reason)}"}

      :throw, value ->
        Logger.error("#{module_name}: Job threw value: #{inspect(value)}")
        {:error, "Thrown value: #{inspect(value)}"}
    end
  end

  defp handle_keyframe_work(%{"clip_id" => clip_id} = args) do
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
