defmodule Heaters.Processing.Embeddings.Workflow do
  @moduledoc """
  Embedding workflow state management.

  Handles the embedding generation lifecycle including state transitions,
  data validation, and result processing for the async embedding pipeline.
  """

  import Ecto.Query, warn: false
  @repo_port Application.compile_env(:heaters, :repo_port, Heaters.Database.EctoAdapter)
  alias Heaters.Media.Clip
  alias Heaters.Processing.Embeddings.Embedding
  alias Heaters.Processing.Embeddings.Types.EmbedResult
  alias Heaters.Media.Queries.Clip, as: ClipQueries
  require Logger

  @doc """
  Transition a clip to "embedding" state.
  """
  @spec start_embedding(integer()) :: {:ok, Clip.t()} | {:error, any()}
  def start_embedding(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id),
         :ok <- validate_state_transition(clip.ingest_state, "embedding") do
      update_clip(clip, %{
        ingest_state: "embedding",
        last_error: nil
      })
    end
  end

  @doc """
  Mark a clip as successfully embedded and create embedding record.
  """
  @spec complete_embedding(integer(), map()) :: {:ok, EmbedResult.t()} | {:error, any()}
  def complete_embedding(clip_id, embedding_data) do
    start_time = System.monotonic_time()

    case @repo_port.transaction(fn ->
           with {:ok, clip} <- ClipQueries.get_clip(clip_id),
                {:ok, updated_clip} <-
                  update_clip(clip, %{
                    ingest_state: "embedded",
                    embedded_at: DateTime.utc_now(),
                    last_error: nil
                  }),
                {:ok, embedding} <- create_embedding(clip_id, embedding_data) do
             {updated_clip, embedding}
           else
             {:error, reason} -> @repo_port.rollback(reason)
           end
         end) do
      {:ok, {_updated_clip, embedding}} ->
        duration_ms =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        embed_result = %EmbedResult{
          status: "success",
          clip_id: clip_id,
          embedding_id: embedding.id,
          model_name: embedding_data["model_name"],
          generation_strategy: embedding_data["generation_strategy"],
          embedding_dim:
            if(is_list(embedding_data["embedding"]),
              do: length(embedding_data["embedding"]),
              else: nil
            ),
          metadata: Map.get(embedding_data, "metadata", %{}),
          duration_ms: duration_ms,
          processed_at: DateTime.utc_now()
        }

        {:ok, embed_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Mark a clip embedding as failed.
  """
  @spec mark_failed(Clip.t() | integer(), String.t(), any()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_failed(clip_or_id, failure_state, error_reason)

  def mark_failed(%Clip{} = clip, failure_state, error_reason) do
    error_message = format_error_message(error_reason)

    update_clip(clip, %{
      ingest_state: failure_state,
      last_error: error_message,
      retry_count: (clip.retry_count || 0) + 1
    })
  end

  def mark_failed(clip_id, failure_state, error_reason) when is_integer(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id) do
      mark_failed(clip, failure_state, error_reason)
    end
  end

  @doc """
  Process successful embedding results from Python task.
  """
  @spec process_embedding_success(Clip.t(), map()) :: {:ok, EmbedResult.t()} | {:error, any()}
  def process_embedding_success(%Clip{} = clip, result) do
    complete_embedding(clip.id, result)
  end

  # Private helper functions

  defp update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> @repo_port.update([])
  end

  defp validate_state_transition(current_state, target_state) do
    case {current_state, target_state} do
      # Valid transitions for embedding
      {"pending_review", "embedding"} ->
        :ok

      {"review_approved", "embedding"} ->
        :ok

      {"keyframed", "embedding"} ->
        :ok

      {"embedding_failed", "embedding"} ->
        :ok

      {"embedding", "embedding"} ->
        # Allow resuming interrupted embedding generation
        :ok

      # Invalid transitions
      _ ->
        Logger.warning("Invalid state transition from '#{current_state}' to '#{target_state}'")
        {:error, :invalid_state_transition}
    end
  end

  defp create_embedding(clip_id, embedding_data) do
    attrs = %{
      clip_id: clip_id,
      model_name: Map.fetch!(embedding_data, "model_name"),
      generation_strategy: Map.fetch!(embedding_data, "generation_strategy"),
      embedding: Map.fetch!(embedding_data, "embedding"),
      metadata: Map.get(embedding_data, "metadata", %{})
    }

    %Embedding{}
    |> Embedding.changeset(attrs)
    |> @repo_port.insert()
    |> case do
      {:ok, embedding} ->
        Logger.info("Successfully created embedding for clip_id: #{clip_id}")
        {:ok, embedding}

      {:error, changeset} ->
        Logger.error(
          "Failed to create embedding for clip_id: #{clip_id}. Changeset errors: #{inspect(changeset.errors)}"
        )

        {:error, "Validation failed: #{format_changeset_errors(changeset)}"}
    end
  rescue
    e ->
      Logger.error("Error creating embedding for clip_id #{clip_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
    |> Enum.join(", ")
  end

  defp format_error_message(error_reason) when is_binary(error_reason), do: error_reason
  defp format_error_message(error_reason), do: inspect(error_reason)
end
