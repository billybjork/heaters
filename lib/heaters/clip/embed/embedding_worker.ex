defmodule Heaters.Clip.Embed.EmbeddingWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Clip.Embed
  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Infrastructure.PyRunner
  require Logger

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
    Logger.info("EmbeddingWorker: Starting embedding for clip_id: #{clip_id}, model: #{model_name}, strategy: #{generation_strategy}")

    with {:ok, clip} <- ClipQueries.get_clip(clip_id),
         :ok <- check_idempotency(clip),
         {:ok, updated_clip} <- Embed.start_embedding(clip_id) do

      Logger.info("EmbeddingWorker: Running PyRunner for clip_id: #{clip_id}")

      # Python task receives explicit parameters for embedding generation
    py_args = %{
        clip_id: updated_clip.id,
        input_s3_path: updated_clip.clip_filepath,
      model_name: model_name,
      generation_strategy: generation_strategy
    }

    case PyRunner.run("embed", py_args) do
        {:ok, result} ->
          Logger.info("EmbeddingWorker: PyRunner succeeded for clip_id: #{clip_id}")

          # Use the new Embed context to process the success
          case Embed.process_embedding_success(updated_clip, result) do
            {:ok, _final_clip} ->
              Logger.info("EmbeddingWorker: Successfully completed embedding for clip_id: #{clip_id}")
              :ok

            {:error, reason} ->
              Logger.error("EmbeddingWorker: Failed to process embedding success: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("EmbeddingWorker: PyRunner failed for clip_id: #{clip_id}, reason: #{inspect(reason)}")

          # Use the new Embed context to mark as failed
          case Embed.mark_failed(updated_clip, "embedding_failed", reason) do
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
        Logger.info("EmbeddingWorker: Clip #{clip_id} already embedded, skipping")
        :ok

      {:error, reason} ->
        Logger.error("EmbeddingWorker: Error in workflow for clip #{clip_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Idempotency check: Skip processing if already embedded
  defp check_idempotency(%{ingest_state: "embedded"}), do: {:error, :already_processed}
  defp check_idempotency(%{ingest_state: "pending_review"}), do: :ok
  defp check_idempotency(%{ingest_state: "review_approved"}), do: :ok
  defp check_idempotency(%{ingest_state: "embedding_failed"}), do: :ok
  defp check_idempotency(%{ingest_state: state}) do
    Logger.warning("EmbeddingWorker: Unexpected clip state '#{state}' for embedding")
    {:error, :invalid_state}
  end
end
