defmodule Heaters.Clips.Embeddings.Worker do
  use Heaters.Infrastructure.Orchestration.WorkerBehavior, queue: :default

  alias Heaters.Clips.Embeddings
  alias Heaters.Infrastructure.PyRunner
  alias Heaters.Infrastructure.Orchestration.WorkerBehavior
  require Logger

  @complete_states ["embedded", "embedding_failed"]

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [handle_work: 1]}

  @impl WorkerBehavior
  def handle_work(%{"clip_id" => clip_id} = args) do
    with {:ok, clip} <- Heaters.Clips.get_clip(clip_id),
         :ok <- check_idempotency(clip) do
      handle_embedding_work(args)
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Clip", clip_id)

      {:error, :already_processed} ->
        WorkerBehavior.handle_already_processed("Clip", clip_id)

      {:error, reason} ->
        Logger.error("EmbeddingWorker: Error in workflow for clip #{clip_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_embedding_work(%{"clip_id" => clip_id}) do
    Logger.info("EmbeddingWorker: Starting embedding generation for clip_id: #{clip_id}")

    with {:ok, updated_clip} <- Embeddings.start_embedding(clip_id) do
      Logger.info("EmbeddingWorker: Running PyRunner for clip_id: #{clip_id}")

      # Build artifact prefix dynamically using the Operations utility
      artifact_prefix = Heaters.Clips.Operations.build_artifact_prefix(updated_clip, "embeddings")

      # Python task receives explicit parameters for embedding generation
      py_args = %{
        clip_id: clip_id,
        artifact_prefix: artifact_prefix,
        keyframes_file: "#{artifact_prefix}/keyframes.json",
        embedding_config:
          %{
            # Add any embedding-specific configuration here
          }
      }

      case PyRunner.run("embedding", py_args) do
        {:ok, result} ->
          Logger.info("EmbeddingWorker: PyRunner succeeded for clip_id: #{clip_id}")

          # Use the Embeddings context to process the success and create embedding records
          case Embeddings.process_embedding_success(updated_clip, result) do
            {:ok,
             %Heaters.Clips.Embeddings.Types.EmbedResult{
               status: "success",
               embedding_id: embedding_id,
               model_name: model
             }} ->
              Logger.info(
                "EmbeddingWorker: Clip #{clip_id} embedding completed successfully (ID: #{embedding_id}, Model: #{model})"
              )

              {:ok, result}

            {:ok, %Heaters.Clips.Embeddings.Types.EmbedResult{status: status}} ->
              Logger.warning(
                "EmbeddingWorker: Embedding finished with unexpected status: #{status}"
              )

              {:error, "Unexpected embedding result status: #{status}"}

            {:error, reason} ->
              Logger.error(
                "EmbeddingWorker: Failed to process embedding success: #{inspect(reason)}"
              )

              {:error, reason}
          end

        {:error, reason} ->
          Logger.error(
            "EmbeddingWorker: PyRunner failed for clip_id: #{clip_id}, reason: #{inspect(reason)}"
          )

          # Use the Embeddings context to mark as failed
          case Embeddings.mark_failed(updated_clip.id, "embedding_failed", reason) do
            {:ok, _updated_clip} ->
              {:error, reason}

            {:error, db_error} ->
              Logger.error("EmbeddingWorker: Failed to mark clip as failed: #{inspect(db_error)}")
              {:error, db_error}
          end
      end
    else
      {:error, reason} ->
        Logger.error("EmbeddingWorker: Error in workflow for clip #{clip_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Idempotency check: Skip processing if already done or has embedding for this model/strategy
  defp check_idempotency(clip) do
    with :ok <- WorkerBehavior.check_complete_states(clip, @complete_states),
         :ok <- check_embedding_exists(clip) do
      :ok
    end
  end

  defp check_embedding_exists(clip) do
    # Check if embedding already exists for this specific model and strategy
    model_name = "clip-vit-base-patch32"
    generation_strategy = "average"

    case Embeddings.has_embedding?(clip.id, model_name, generation_strategy) do
      # No embedding exists, clip is ready
      false -> :ok
      # Embedding exists, skip processing
      true -> {:error, :already_processed}
    end
  end
end
