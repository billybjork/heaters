defmodule Heaters.Workers.Clips.EmbeddingWorker do
  use Oban.Worker, queue: :default

  alias Heaters.Clips.Embeddings
  alias Heaters.Infrastructure.PyRunner
  require Logger

  @complete_states ["embedded", "embedding_failed"]

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [perform: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    module_name = __MODULE__ |> Module.split() |> List.last()
    Logger.info("#{module_name}: Starting job with args: #{inspect(args)}")

    start_time = System.monotonic_time()

    try do
      case handle_embedding_work(args) do
        {:ok, result} ->
          duration_ms =
            System.convert_time_unit(
              System.monotonic_time() - start_time,
              :native,
              :millisecond
            )

          Logger.info("#{module_name}: Job completed successfully in #{duration_ms}ms")
          {:ok, result}

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

        other ->
          Logger.error("#{module_name}: Job returned unexpected result: #{inspect(other)}")
          {:error, "Unexpected return value: #{inspect(other)}"}
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

  defp handle_embedding_work(%{"clip_id" => clip_id}) do
    Logger.info("EmbeddingWorker: Starting embedding generation for clip_id: #{clip_id}")

    with {:ok, clip} <- Heaters.Clips.get_clip(clip_id),
         {:clip_ready, true} <- {:clip_ready, clip_ready?(clip)},
         {:ok, updated_clip} <- Embeddings.start_embedding(clip_id) do
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
        # No embedding exists, clip is ready
        false -> true
        # Embedding exists, skip processing
        true -> false
      end
    end
  end
end
