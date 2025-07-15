defmodule Heaters.Clips.Embeddings.Worker do
  use Heaters.Infrastructure.Orchestration.WorkerBehavior,
    queue: :default,
    # 10 minutes, prevent duplicate embedding jobs
    unique: [period: 600, fields: [:args]]

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

  defp handle_embedding_work(%{"clip_id" => clip_id} = args) do
    Logger.info("EmbeddingWorker: Starting embedding generation for clip_id: #{clip_id}")

    with {:ok, clip} <- Heaters.Clips.get_clip(clip_id),
         {:ok, updated_clip} <- ensure_embedding_state(clip_id, clip),
         {:ok, clip_with_artifacts} <- Heaters.Clips.get_clip_with_artifacts(clip_id) do
      Logger.info("EmbeddingWorker: Running PyRunner for clip_id: #{clip_id}")

      # Extract keyframe S3 keys from clip artifacts
      keyframe_s3_keys =
        clip_with_artifacts.clip_artifacts
        |> Enum.filter(&(&1.artifact_type == "keyframe"))
        |> Enum.map(& &1.s3_key)

      # Get model name and generation strategy from job args
      model_name = Map.get(args, "model_name", "openai/clip-vit-base-patch32")
      generation_strategy = Map.get(args, "generation_strategy", "keyframe_multi_avg")

      # Python task receives explicit parameters for embedding generation
      py_args = %{
        clip_id: clip_id,
        keyframe_s3_keys: keyframe_s3_keys,
        model_name: model_name,
        generation_strategy: generation_strategy
      }

      case PyRunner.run("embed", py_args) do
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

  # Helper function to ensure clip is in embedding state, handling resumable processing
  defp ensure_embedding_state(clip_id, clip) do
    case clip.ingest_state do
      "embedding" ->
        Logger.info("EmbeddingWorker: Clip #{clip_id} already in embedding state, resuming")
        {:ok, clip}

      _ ->
        # Transition to embedding state for other valid states
        Embeddings.start_embedding(clip_id)
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
    model_name = "openai/clip-vit-base-patch32"
    generation_strategy = "keyframe_multi_avg"

    case Embeddings.has_embedding?(clip.id, model_name, generation_strategy) do
      # No embedding exists, clip is ready
      false -> :ok
      # Embedding exists, skip processing
      true -> {:error, :already_processed}
    end
  end
end
