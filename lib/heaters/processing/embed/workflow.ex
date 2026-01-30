defmodule Heaters.Processing.Embed.Workflow do
  @moduledoc """
  Embedding workflow state management.

  Handles the embedding generation lifecycle including state transitions,
  data validation, and result processing for the async embedding pipeline.
  """

  import Ecto.Query, warn: false
  alias Heaters.Media.Clip
  alias Heaters.Media.Clips
  alias Heaters.Processing.Embed.Embedding
  alias Heaters.Processing.Embed.Types.EmbedResult
  alias Heaters.Repo
  require Logger

  @doc """
  Transition a clip to :embedding state.
  """
  @spec start_embedding(integer()) :: {:ok, Clip.t()} | {:error, any()}
  def start_embedding(clip_id) do
    with {:ok, clip} <- Clips.get_clip(clip_id),
         :ok <- validate_state_transition(clip.ingest_state, :embedding) do
      update_clip(clip, %{
        ingest_state: :embedding,
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

    case execute_embedding_transaction(clip_id, embedding_data) do
      {:ok, {_updated_clip, embedding}} ->
        {:ok, build_embed_result(clip_id, embedding, embedding_data, start_time)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_embedding_transaction(clip_id, embedding_data) do
    Repo.transaction(fn ->
      with {:ok, clip} <- Clips.get_clip(clip_id),
           {:ok, updated_clip} <- update_clip(clip, embedding_state_attrs()),
           {:ok, embedding} <- create_embedding(clip_id, embedding_data) do
        {updated_clip, embedding}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp embedding_state_attrs do
    %{ingest_state: :embedded, embedded_at: DateTime.utc_now(), last_error: nil}
  end

  defp build_embed_result(clip_id, embedding, embedding_data, start_time) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    %EmbedResult{
      status: "success",
      clip_id: clip_id,
      embedding_id: embedding.id,
      model_name: embedding_data["model_name"],
      generation_strategy: embedding_data["generation_strategy"],
      embedding_dim: get_embedding_dim(embedding_data),
      metadata: Map.get(embedding_data, "metadata", %{}),
      duration_ms: duration_ms,
      processed_at: DateTime.utc_now()
    }
  end

  defp get_embedding_dim(embedding_data) do
    case embedding_data[:embedding] do
      list when is_list(list) -> length(list)
      _ -> nil
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
    with {:ok, clip} <- Clips.get_clip(clip_id) do
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
    |> Repo.update([])
  end

  defp validate_state_transition(current_state, target_state) do
    case {current_state, target_state} do
      # Valid transitions for embedding
      {:pending_review, :embedding} ->
        :ok

      {:review_approved, :embedding} ->
        :ok

      {:keyframed, :embedding} ->
        :ok

      {:embedding_failed, :embedding} ->
        :ok

      {:embedding, :embedding} ->
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
      model_version: Map.get(embedding_data, "model_version"),
      generation_strategy: Map.fetch!(embedding_data, "generation_strategy"),
      embedding: Map.fetch!(embedding_data, "embedding"),
      embedding_dim:
        Map.get(embedding_data, "vector_dimensions") ||
          get_in(embedding_data, ["metadata", "embedding_dimension"])
    }

    changeset = Embedding.changeset(%Embedding{}, attrs)

    Repo.insert(
      changeset,
      on_conflict: {:replace, [:embedding, :embedding_dim, :model_version, :updated_at]},
      conflict_target: [:clip_id, :model_name, :generation_strategy]
    )
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
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _}} ->
      "#{field}: #{message}"
    end)
  end

  defp format_error_message(error_reason) when is_binary(error_reason), do: error_reason
  defp format_error_message(error_reason), do: inspect(error_reason)
end
