defmodule Heaters.Workers.Clips.EmbeddingWorker do
  use Oban.Worker, queue: :default

  alias Heaters.Clips.Embeddings
  alias Heaters.Infrastructure.PyRunner
  require Logger

  @complete_states ["embedded", "embedding_failed"]

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [perform: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id}}) do
    Logger.info("EmbeddingWorker: Starting embedding generation for clip_id: #{clip_id}")

         with {:ok, clip} <- Heaters.Clips.get_clip(clip_id),
         {:clip_ready, true} <- {:clip_ready, clip_ready?(clip)},
         {:ok, updated_clip} <- Embeddings.start_embedding(clip_id) do
      Logger.info("EmbeddingWorker: Running PyRunner for clip_id: #{clip_id}")

      # Python task receives explicit parameters for embedding generation
      py_args = %{
        clip_id: clip_id,
        artifact_prefix: updated_clip.artifact_prefix,
        keyframes_file: "#{updated_clip.artifact_prefix}/keyframes.json",
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
             %Embeddings.EmbedResult{
               status: "embedded",
               embedding_id: embedding_id,
               model_name: model
             }} ->
              Logger.info(
                "EmbeddingWorker: Clip #{clip_id} embedding completed successfully (ID: #{embedding_id}, Model: #{model})"
              )

              {:ok, result}

            {:ok, %Embeddings.EmbedResult{status: status}} ->
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
      {:error, :not_found} ->
        Logger.warning("EmbeddingWorker: Clip #{clip_id} not found, likely deleted")
        :ok

      {:clip_ready, false} ->
        Logger.info("EmbeddingWorker: Clip #{clip_id} already processed, skipping")
        :ok

      {:error, reason} ->
        Logger.error("EmbeddingWorker: Error in workflow for clip #{clip_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Idempotency check: Skip processing if already done or has embedding for this model/strategy
  defp clip_ready?(clip) do
    # Skip if clip is already in a complete state
    if clip.ingest_state in @complete_states do
      false
    else
      # Check if embedding already exists for this specific model and strategy
      model_name = "clip-vit-base-patch32"
      generation_strategy = "average"

      case Embeddings.has_embedding?(clip.id, model_name, generation_strategy) do
        false -> true  # No embedding exists, clip is ready
        true -> false  # Embedding exists, skip processing
      end
    end
  end
end
