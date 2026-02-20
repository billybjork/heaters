defmodule Heaters.Processing.Embed.Worker do
  @moduledoc """
  Worker for generating vector embeddings from clip keyframes using Python.
  """

  use Heaters.Pipeline.WorkerBehavior,
    queue: :default,
    # 10 minutes, prevent duplicate embedding jobs
    unique: [period: 600, fields: [:args]]

  alias Heaters.Media.Clips
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Processing.Embed.Search, as: EmbedSearch
  alias Heaters.Processing.Embed.Workflow
  alias Heaters.Processing.Support.PythonRunner, as: PyRunner
  alias Heaters.Processing.Support.ResultBuilder
  alias Heaters.Storage.PipelineCache.TempCache
  require Logger

  # Suppress dialyzer warnings for PyRunner calls when environment is not configured.
  #
  # JUSTIFICATION: PyRunner requires DEV_DATABASE_URL and DEV_S3_BUCKET_NAME environment
  # variables. When not set, PyRunner always fails, making success patterns unreachable.
  # In configured environments, these functions will succeed normally.
  #
  # The functions below are called within the PyRunner execution path, so dialyzer
  # believes they are unreachable when PyRunner always fails.
  @dialyzer {:nowarn_function,
             [
               handle_work: 1,
               handle_embedding_work: 1,
               run_embedding_task: 2,
               execute_python_embedding: 2,
               process_embedding_result: 3,
               handle_embedding_error: 2,
               extract_embeddings_count: 1,
               extract_keyframes_count: 1,
               extract_vector_dimensions: 1,
               extract_processing_stats: 1
             ]}

  @impl WorkerBehavior
  def handle_work(%{"clip_id" => clip_id} = args) do
    with {:ok, clip} <- Clips.get_clip(clip_id),
         :ok <- check_idempotency(clip, args) do
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

  defp run_embedding_task(clip, args) do
    Logger.info("EmbeddingWorker: Running Python embedding task for clip #{clip.id}")

    with {:ok, image_paths} <- fetch_local_keyframe_paths(clip),
         py_args = build_py_args(clip, image_paths, args),
         {:ok, result} <- execute_python_embedding(clip, py_args) do
      process_embedding_result(clip, result, py_args)
    else
      {:error, reason} ->
        handle_embedding_error(clip, reason)
    end
  end

  defp build_py_args(clip, image_paths, args) do
    %{
      clip_id: clip.id,
      image_paths: image_paths,
      model_name: Map.get(args, "model_name"),
      generation_strategy: Map.get(args, "generation_strategy")
    }
  end

  defp execute_python_embedding(clip, py_args) do
    case PyRunner.run_python_task("embed", py_args, timeout: :timer.minutes(5)) do
      {:ok, result} ->
        Logger.info(
          "EmbeddingWorker: Python embedding completed successfully for clip #{clip.id}"
        )

        {:ok, result}

      {:error, reason} ->
        Logger.error(
          "EmbeddingWorker: Python embedding failed for clip #{clip.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp process_embedding_result(clip, result, py_args) do
    case Workflow.process_embedding_success(clip, result) do
      {:ok, _updated_clip} ->
        embedding_result =
          ResultBuilder.embedding_success(clip.id, extract_embeddings_count(result), %{
            keyframes_processed: extract_keyframes_count(py_args[:image_paths]),
            vector_dimensions: extract_vector_dimensions(result),
            processing_stats: extract_processing_stats(result),
            metadata: result
          })

        ResultBuilder.log_result(__MODULE__, embedding_result)
        embedding_result

      {:error, reason} ->
        Logger.error("EmbeddingWorker: Failed to process embedding success: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_embedding_error(clip, reason) do
    Logger.error("EmbeddingWorker: Failed embedding for clip #{clip.id}: #{inspect(reason)}")
    Workflow.mark_failed(clip, :embedding_failed, reason)
  end

  defp extract_keyframe_s3_keys(clip) do
    case clip.clip_artifacts do
      %Ecto.Association.NotLoaded{} ->
        Logger.warning("EmbeddingWorker: clip_artifacts not preloaded for clip #{clip.id}")
        []

      artifacts when is_list(artifacts) ->
        artifacts
        |> Enum.filter(&(&1.artifact_type == :keyframe))
        |> Enum.map(& &1.s3_key)
    end
  end

  defp fetch_local_keyframe_paths(clip) do
    s3_keys = extract_keyframe_s3_keys(clip)
    download_keyframe_paths(s3_keys)
  end

  defp download_keyframe_paths([]), do: {:error, "No keyframe artifacts found"}

  defp download_keyframe_paths(s3_keys) do
    results = Enum.map(s3_keys, &download_single_keyframe/1)
    collect_keyframe_results(results)
  end

  defp download_single_keyframe(s3_key) do
    case TempCache.get_or_download(s3_key, operation_name: "Embedding") do
      {:ok, path, _origin} -> {:ok, path}
      {:error, reason} -> {:error, {reason, s3_key}}
    end
  end

  defp collect_keyframe_results(results) do
    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {oks, []} ->
        {:ok, Enum.map(oks, fn {:ok, p} -> p end)}

      {_oks, errs} ->
        {:error, {:failed_to_prepare_keyframes, Enum.map(errs, fn {:error, e} -> e end)}}
    end
  end

  # Idempotency check: Only skip if an embedding exists for this model+strategy
  defp check_idempotency(clip, args) do
    model_name = Map.get(args, "model_name")
    generation_strategy = Map.get(args, "generation_strategy")

    case EmbedSearch.has_embedding?(
           clip.id,
           model_name,
           generation_strategy
         ) do
      true -> {:error, :already_processed}
      false -> :ok
    end
  end

  # Helper functions for extracting metrics from Python embedding results
  defp extract_embeddings_count(result) when is_map(result) do
    cond do
      is_list(result["embedding"]) -> 1
      result["embeddings_count"] -> result["embeddings_count"]
      result["total_embeddings"] -> result["total_embeddings"]
      true -> 0
    end
  end

  defp extract_embeddings_count(_), do: 0

  defp extract_keyframes_count(keyframe_artifacts) when is_list(keyframe_artifacts) do
    length(keyframe_artifacts)
  end

  defp extract_keyframes_count(_), do: 0

  defp extract_vector_dimensions(result) when is_map(result) do
    result["vector_dimensions"] ||
      get_in(result, ["metadata", "embedding_dimension"]) ||
      result["embedding_size"]
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
