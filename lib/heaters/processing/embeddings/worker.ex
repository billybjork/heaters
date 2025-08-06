defmodule Heaters.Processing.Embeddings.Worker do
  use Heaters.Pipeline.WorkerBehavior,
    queue: :default,
    # 10 minutes, prevent duplicate embedding jobs
    unique: [period: 600, fields: [:args]]

  alias Heaters.Processing.Embeddings.Workflow
  alias Heaters.Processing.Support.PythonRunner, as: PyRunner
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Media.Clips
  alias Heaters.Processing.Support.ResultBuilder
  require Logger

  # Suppress dialyzer warnings for PyRunner calls when environment is not configured.
  #
  # JUSTIFICATION: PyRunner requires DEV_DATABASE_URL and DEV_S3_BUCKET_NAME environment
  # variables. When not set, PyRunner always fails, making success patterns unreachable.
  # In configured environments, these functions will succeed normally.
  @dialyzer {:nowarn_function,
             [
               handle_embedding_work: 1,
               run_embedding_task: 2,
               extract_embeddings_count: 1,
               extract_keyframes_count: 1,
               extract_vector_dimensions: 1,
               extract_processing_stats: 1
             ]}

  @complete_states [:embedded]

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [handle_work: 1]}

  @impl WorkerBehavior
  def handle_work(%{"clip_id" => clip_id} = args) do
    with {:ok, clip} <- Clips.get_clip(clip_id),
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

    with {:ok, clip} <- Clips.get_clip(clip_id),
         {:ok, _updated_clip} <- ensure_embedding_state(clip_id, clip),
         {:ok, clip_with_artifacts} <- Clips.get_clip_with_artifacts(clip_id) do
      run_embedding_task(clip_with_artifacts, args)
    else
      {:error, reason} ->
        Logger.error(
          "EmbeddingWorker: Failed to prepare embedding for clip #{clip_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp ensure_embedding_state(clip_id, clip) do
    case clip.ingest_state do
      :embedding ->
        Logger.info("EmbeddingWorker: Clip #{clip_id} already in embedding state, resuming")
        {:ok, clip}

      _ ->
        # Transition to embedding state
        Workflow.start_embedding(clip_id)
    end
  end

  defp run_embedding_task(clip, _args) do
    Logger.info("EmbeddingWorker: Running Python embedding task for clip #{clip.id}")

    py_args = %{
      clip_id: clip.id,
      clip_filepath: clip.clip_filepath,
      keyframe_artifacts: extract_keyframe_artifacts(clip)
    }

    case PyRunner.run_python_task(:embedding, py_args, timeout: :timer.minutes(5)) do
      {:ok, result} ->
        Logger.info(
          "EmbeddingWorker: Python embedding completed successfully for clip #{clip.id}"
        )

        case Workflow.process_embedding_success(clip, result) do
          {:ok, _updated_clip} ->
            # Build structured result with embedding metrics
            embedding_result =
              ResultBuilder.embedding_success(clip.id, extract_embeddings_count(result), %{
                keyframes_processed: extract_keyframes_count(py_args[:keyframe_artifacts]),
                vector_dimensions: extract_vector_dimensions(result),
                processing_stats: extract_processing_stats(result),
                metadata: result
              })

            # Log structured result for observability
            ResultBuilder.log_result(__MODULE__, embedding_result)
            embedding_result

          {:error, reason} ->
            Logger.error(
              "EmbeddingWorker: Failed to process embedding success: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error(
          "EmbeddingWorker: Python embedding failed for clip #{clip.id}: #{inspect(reason)}"
        )

        Workflow.mark_failed(clip, :embedding_failed, reason)
    end
  end

  defp extract_keyframe_artifacts(clip) do
    case clip.clip_artifacts do
      %Ecto.Association.NotLoaded{} ->
        Logger.warning("EmbeddingWorker: clip_artifacts not preloaded for clip #{clip.id}")
        []

      artifacts when is_list(artifacts) ->
        artifacts
        |> Enum.filter(&(&1.artifact_type == :keyframe))
        |> Enum.map(fn artifact ->
          %{
            id: artifact.id,
            s3_key: artifact.s3_key,
            s3_url: artifact.s3_url
          }
        end)
    end
  end

  # Idempotency check: Skip processing if already done
  defp check_idempotency(clip) do
    WorkerBehavior.check_complete_states(clip, @complete_states)
  end

  # Helper functions for extracting metrics from Python embedding results
  defp extract_embeddings_count(result) when is_map(result) do
    result["embeddings_count"] || result["total_embeddings"] || 0
  end

  defp extract_embeddings_count(_), do: 0

  defp extract_keyframes_count(keyframe_artifacts) when is_list(keyframe_artifacts) do
    length(keyframe_artifacts)
  end

  defp extract_keyframes_count(_), do: 0

  defp extract_vector_dimensions(result) when is_map(result) do
    result["vector_dimensions"] || result["embedding_size"]
  end

  defp extract_vector_dimensions(_), do: nil

  defp extract_processing_stats(result) when is_map(result) do
    %{
      processing_time_seconds: result["processing_time"],
      model_used: result["model"],
      total_vectors: result["total_vectors"],
      success_rate: result["success_rate"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp extract_processing_stats(_), do: %{}
end
