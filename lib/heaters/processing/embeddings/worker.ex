defmodule Heaters.Processing.Embeddings.Worker do
  use Heaters.Pipeline.WorkerBehavior,
    queue: :default,
    # 10 minutes, prevent duplicate embedding jobs
    unique: [period: 600, fields: [:args]]

  alias Heaters.Processing.Embeddings
  alias Heaters.Processing.Py.Runner, as: PyRunner
  alias Heaters.Pipeline.WorkerBehavior
  require Logger

  @complete_states ["embedded"]

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [handle_work: 1]}

  @impl WorkerBehavior
  def handle_work(%{"clip_id" => clip_id} = args) do
    with {:ok, clip} <- Heaters.Media.get_clip(clip_id),
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

    with {:ok, clip} <- Heaters.Media.get_clip(clip_id),
         {:ok, _updated_clip} <- ensure_embedding_state(clip_id, clip),
         {:ok, clip_with_artifacts} <- Heaters.Media.get_clip_with_artifacts(clip_id) do
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
      "embedding" ->
        Logger.info("EmbeddingWorker: Clip #{clip_id} already in embedding state, resuming")
        {:ok, clip}

      _ ->
        # Transition to embedding state
        Embeddings.start_embedding(clip_id)
    end
  end

  defp run_embedding_task(clip, _args) do
    Logger.info("EmbeddingWorker: Running Python embedding task for clip #{clip.id}")

    py_args = %{
      clip_id: clip.id,
      clip_filepath: clip.clip_filepath,
      keyframe_artifacts: extract_keyframe_artifacts(clip)
    }

    case PyRunner.run("embedding", py_args, timeout: :timer.minutes(5)) do
      {:ok, result} ->
        Logger.info(
          "EmbeddingWorker: Python embedding completed successfully for clip #{clip.id}"
        )

        Embeddings.process_embedding_success(clip, result)

      {:error, reason} ->
        Logger.error(
          "EmbeddingWorker: Python embedding failed for clip #{clip.id}: #{inspect(reason)}"
        )

        Embeddings.mark_failed(clip, "embedding_failed", reason)
    end
  end

  defp extract_keyframe_artifacts(clip) do
    case clip.clip_artifacts do
      nil ->
        []

      artifacts when is_list(artifacts) ->
        artifacts
        |> Enum.filter(&(&1.artifact_type == "keyframe"))
        |> Enum.map(fn artifact ->
          %{
            id: artifact.id,
            s3_key: artifact.s3_key,
            s3_url: artifact.s3_url
          }
        end)

      _ ->
        []
    end
  end

  # Idempotency check: Skip processing if already done
  defp check_idempotency(clip) do
    WorkerBehavior.check_complete_states(clip, @complete_states)
  end
end
