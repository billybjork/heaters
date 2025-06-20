defmodule Heaters.Workers.Clip.EmbeddingWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Clip.Embed
  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Infrastructure.PyRunner
  require Logger

  @complete_states ["embedded", "embedding_failed"]

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [perform: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "clip_id" => clip_id,
          "model_name" => model_name,
          "generation_strategy" => generation_strategy
        }
      }) do
    Logger.info("EmbeddingWorker: Starting embedding generation for clip_id: #{clip_id}")

    with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip, model_name, generation_strategy),
         {:ok, updated_clip} <- Embed.start_embedding(clip_id) do

      Logger.info("EmbeddingWorker: Running PyRunner for clip_id: #{clip_id}")

      # Python task receives explicit parameters for embedding generation
      py_args = %{
        clip_id: updated_clip.id,
        input_s3_path: updated_clip.clip_filepath,
        model_name: model_name,
        generation_strategy: generation_strategy,
        embedding_config: %{
          # Add any embedding-specific configuration here
        }
      }

      case PyRunner.run("embedding", py_args) do
        {:ok, result} ->
          Logger.info("EmbeddingWorker: PyRunner succeeded for clip_id: #{clip_id}")

          # Use the Embed context to process the success and create embedding records
          case Embed.process_embedding_success(updated_clip, result) do
            {:ok, _final_clip} ->
              Logger.info("EmbeddingWorker: Clip #{clip_id} embedding completed successfully")
              :ok

            {:error, reason} ->
              Logger.error("EmbeddingWorker: Failed to process embedding success: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("EmbeddingWorker: PyRunner failed for clip_id: #{clip_id}, reason: #{inspect(reason)}")

          # Use the Embed context to mark as failed
          case Embed.mark_failed(updated_clip.id, "embedding_failed", reason) do
            {:ok, _} -> {:error, reason}
            {:error, db_error} ->
              Logger.error("EmbeddingWorker: Failed to mark clip as failed: #{inspect(db_error)}")
              {:error, reason}
          end
      end
    else
      {:error, :not_found} ->
        Logger.warning("EmbeddingWorker: Clip #{clip_id} not found, likely deleted")
        :ok

      {:error, :already_processed} ->
        Logger.info("EmbeddingWorker: Clip #{clip_id} already processed, skipping")
        :ok

      {:error, reason} ->
        Logger.error("EmbeddingWorker: Error in workflow for clip #{clip_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Idempotency check: Skip processing if already done or has embedding for this model/strategy
  defp check_idempotency(%{ingest_state: state}, _model_name, _generation_strategy) when state in @complete_states do
    {:error, :already_processed}
  end

  defp check_idempotency(clip, model_name, generation_strategy) do
    # Check if embedding already exists for this specific model and strategy
    case Embed.has_embedding?(clip.id, model_name, generation_strategy) do
      true -> {:error, :already_processed}
      false -> :ok
    end
  end
end
