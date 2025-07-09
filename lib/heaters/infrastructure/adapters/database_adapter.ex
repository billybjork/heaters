defmodule Heaters.Infrastructure.Adapters.DatabaseAdapter do
  @moduledoc """
  Database adapter providing consistent I/O interface for domain operations.

  This adapter wraps existing Queries modules with standardized error handling
  and provides a clean interface for domain operations to access data.
  All functions in this module perform I/O operations.
  """

  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Clips.Clip

  @doc """
  Get a clip by ID with artifacts preloaded.

  ## Examples

      {:ok, clip} = DatabaseAdapter.get_clip_with_artifacts(123)
      {:error, :not_found} = DatabaseAdapter.get_clip_with_artifacts(999)
  """
  @spec get_clip_with_artifacts(integer()) :: {:ok, Clip.t()} | {:error, atom()}
  def get_clip_with_artifacts(clip_id) when is_integer(clip_id) do
    ClipQueries.get_clip_with_artifacts(clip_id)
  end

  @doc """
  Get a clip by ID without preloading associations.
  """
  @spec get_clip(integer()) :: {:ok, Clip.t()} | {:error, atom()}
  def get_clip(clip_id) when is_integer(clip_id) do
    ClipQueries.get_clip(clip_id)
  end

  @doc """
  Update a clip's state.

  ## Examples

      {:ok, updated_clip} = DatabaseAdapter.update_clip_state(clip, "generating_sprite")
      {:error, changeset} = DatabaseAdapter.update_clip_state(clip, "invalid_state")
  """
  @spec update_clip_state(Clip.t(), String.t()) :: {:ok, Clip.t()} | {:error, any()}
  def update_clip_state(%Clip{} = clip, new_state) when is_binary(new_state) do
    ClipQueries.update_clip(clip, %{ingest_state: new_state})
  end

  @doc """
  Update a clip with arbitrary attributes.
  """
  @spec update_clip(Clip.t(), map()) :: {:ok, Clip.t()} | {:error, any()}
  def update_clip(%Clip{} = clip, attrs) when is_map(attrs) do
    ClipQueries.update_clip(clip, attrs)
  end

  @doc """
  Mark a clip as failed with error information.

  Convenience function for handling failure states with error tracking.
  """
  @spec mark_clip_failed(Clip.t(), String.t(), String.t()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_clip_failed(%Clip{} = clip, failure_state, error_message)
      when is_binary(failure_state) and is_binary(error_message) do
    attrs = %{
      ingest_state: failure_state,
      last_error: error_message,
      retry_count: (clip.retry_count || 0) + 1
    }

    ClipQueries.update_clip(clip, attrs)
  end

  @doc """
  Get clips by ingest state.
  Useful for the Dispatcher to find clips ready for processing.
  """
  @spec get_clips_by_state(String.t()) :: [Clip.t()]
  def get_clips_by_state(state) when is_binary(state) do
    ClipQueries.get_clips_by_state(state)
  end

  @doc """
  Get count of clips in pending review.
  """
  @spec pending_review_count() :: integer()
  def pending_review_count do
    ClipQueries.pending_review_count()
  end

  @doc """
  Validate that a clip exists and return it if found.
  Similar to get_clip but provides more explicit error handling.
  """
  @spec validate_clip_exists(integer()) :: {:ok, Clip.t()} | {:error, :clip_not_found}
  def validate_clip_exists(clip_id) when is_integer(clip_id) do
    case get_clip(clip_id) do
      {:ok, clip} -> {:ok, clip}
      {:error, :not_found} -> {:error, :clip_not_found}
    end
  end

  @doc """
  Check if a clip is in a specific state.
  Useful for domain validation that requires database checks.
  """
  @spec clip_in_state?(integer(), String.t()) :: {:ok, boolean()} | {:error, atom()}
  def clip_in_state?(clip_id, expected_state)
      when is_integer(clip_id) and is_binary(expected_state) do
    case get_clip(clip_id) do
      {:ok, %Clip{ingest_state: ^expected_state}} -> {:ok, true}
      {:ok, %Clip{}} -> {:ok, false}
      error -> error
    end
  end

  @doc """
  Create multiple clips in a single batch operation.

  ## Parameters
  - `clips_attrs`: List of clip attribute maps

  ## Returns
  - `{:ok, clips}` with list of created clips on success
  - `{:error, reason}` on failure

  ## Examples

      clips_attrs = [%{source_video_id: 1, clip_filepath: "clip1.mp4"}, ...]
      {:ok, clips} = DatabaseAdapter.create_clips(clips_attrs)
  """
  @spec create_clips([map()]) :: {:ok, [Clip.t()]} | {:error, any()}
  def create_clips(clips_attrs) when is_list(clips_attrs) do
    alias Heaters.Repo

    # Validate all clips before bulk insert
    validated_changesets = Enum.map(clips_attrs, &Clip.changeset(%Clip{}, &1))

    case validate_clip_changesets(validated_changesets) do
      :ok ->
        case Repo.insert_all(Clip, clips_attrs, returning: true) do
          {count, clips} when count > 0 -> {:ok, clips}
          {0, _} -> {:error, "No clips were created"}
        end

      {:error, errors} ->
        {:error, "Validation failed: #{format_clip_validation_errors(errors)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Batch update clips matching a query with the given attributes.

  ## Parameters
  - `queryable`: Ecto query or module to update
  - `updates`: Map of attributes to update

  ## Returns
  - `{:ok, updated_count}` with number of updated records
  - `{:error, reason}` on failure

  ## Examples

      query = from(c in Clip, where: c.id in ^clip_ids)
      {:ok, count} = DatabaseAdapter.batch_update_clips(query, %{ingest_state: "merged"})
  """
  @spec batch_update_clips(Ecto.Queryable.t(), map()) :: {:ok, integer()} | {:error, any()}
  def batch_update_clips(queryable, updates) when is_map(updates) do
    alias Heaters.Repo

    case Repo.update_all(queryable, set: Enum.to_list(updates)) do
      {count, _} -> {:ok, count}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Insert a single clip and return it.

  ## Parameters
  - `clip_attrs`: Clip attributes map

  ## Returns
  - `{:ok, clip}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec create_clip(map()) :: {:ok, Clip.t()} | {:error, any()}
  def create_clip(clip_attrs) when is_map(clip_attrs) do
    alias Heaters.Repo

    %Clip{}
    |> Clip.changeset(clip_attrs)
    |> Repo.insert()
  end

  # Private helper functions

  defp validate_clip_changesets(changesets) do
    errors =
      changesets
      |> Enum.with_index()
      |> Enum.filter(fn {changeset, _index} -> not changeset.valid? end)
      |> Enum.map(fn {changeset, index} -> {index, changeset.errors} end)

    if Enum.empty?(errors) do
      :ok
    else
      {:error, errors}
    end
  end

  defp format_clip_validation_errors(errors) do
    errors
    |> Enum.map(fn {index, changeset_errors} ->
      error_messages =
        changeset_errors
        |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
        |> Enum.join(", ")

      "Clip #{index}: #{error_messages}"
    end)
    |> Enum.join("; ")
  end
end
