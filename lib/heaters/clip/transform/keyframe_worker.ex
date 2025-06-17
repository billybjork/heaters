defmodule Heaters.Clip.Transform.KeyframeWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Clip.Transform
  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Infrastructure.PythonRunner
  alias Heaters.Clip.Review.SpriteWorker
  require Logger

  # Dialyzer cannot statically verify PythonRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [perform: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id}} = job) do
    # Default strategy if not provided in args
    strategy = Map.get(job.args, "strategy", "midpoint")

    Logger.info("KeyframeWorker: Starting keyframing for clip_id: #{clip_id} with strategy: #{strategy}")

    with {:ok, clip} <- ClipQueries.get_clip(clip_id),
         :ok <- check_idempotency(clip),
         {:ok, updated_clip} <- Transform.start_keyframing_from_approved(clip_id) do

      Logger.info("KeyframeWorker: Running PythonRunner for clip_id: #{clip_id}")

      # Python task receives explicit S3 paths and processing parameters
      py_args = %{
        clip_id: updated_clip.id,
        input_s3_path: updated_clip.clip_filepath,
        output_s3_prefix: Transform.build_keyframe_prefix(updated_clip),
        strategy: strategy
      }

      case PythonRunner.run("keyframe", py_args) do
        {:ok, result} ->
          Logger.info("KeyframeWorker: PythonRunner succeeded for clip_id: #{clip_id}")

          # Use the new Transform context to process the success
          case Transform.process_keyframe_success(updated_clip, result) do
            {:ok, final_clip} ->
              # Enqueue the next worker in the chain (sprite generation)
              case SpriteWorker.new(%{clip_id: final_clip.id}) |> Oban.insert() do
                {:ok, _job} ->
                  Logger.info("KeyframeWorker: Enqueued sprite worker for clip_id: #{clip_id}")
                  :ok

                {:error, reason} ->
                  Logger.error("KeyframeWorker: Failed to enqueue sprite worker: #{inspect(reason)}")
                  {:error, "Failed to enqueue sprite worker: #{inspect(reason)}"}
              end

            {:error, reason} ->
              Logger.error("KeyframeWorker: Failed to process keyframe success: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("KeyframeWorker: PythonRunner failed for clip_id: #{clip_id}, reason: #{inspect(reason)}")

          # Use the new Transform context to mark as failed
          case Transform.mark_failed(updated_clip, "keyframing_failed", reason) do
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

  # Idempotency check: Skip processing if already done or in a terminal failure state
  defp check_idempotency(%{ingest_state: "keyframed"}), do: {:error, :already_processed}
  defp check_idempotency(%{ingest_state: "embedding_failed"}), do: {:error, :already_processed}
  defp check_idempotency(%{ingest_state: "embedded"}), do: {:error, :already_processed}
  defp check_idempotency(%{ingest_state: "review_approved"}), do: :ok
  defp check_idempotency(%{ingest_state: "keyframing_failed"}), do: :ok
  defp check_idempotency(%{ingest_state: "keyframe_failed"}), do: :ok
  defp check_idempotency(%{ingest_state: state}) do
    Logger.warning("KeyframeWorker: Unexpected clip state '#{state}' for keyframing")
    {:error, :invalid_state}
  end
end
