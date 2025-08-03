defmodule Heaters.Media.Clips do
  @moduledoc """
  Core domain operations for `Heaters.Media.Clip` objects.

  This module consolidates clip domain operations into a single, cohesive interface.
  The actual schema definition remains in `Heaters.Media.Clip`.

  ## When to Add Functions Here

  - **CRUD Operations**: Creating, reading, updating, deleting clips
  - **State Management**: Clip state transitions and failure handling
  - **Domain Validation**: Business logic validation (existence checks, state validation)
  - **Bulk Operations**: Batch processing of clips
  - **Generic Queries**: Simple state-based queries (`get_clips_by_state`)

  ## When NOT to Add Functions Here

  - **Pipeline Orchestration**: Queries for pipeline stage discovery → `Pipeline.Queries`
  - **Review Workflow**: Queue management, review counts → `Review.Queue`
  - **Processing-Specific**: Single processing stage queries → respective processing modules

  ## Design Philosophy

  - **Schema Separation**: `Heaters.Media.Clip` defines the data structure
  - **Domain Focus**: This module provides core clip business operations
  - **Pure Domain Logic**: No pipeline orchestration or workflow-specific concerns
  - **Single Import**: `alias Heaters.Media.Clips` provides access to clip domain operations

  All DB interaction goes through `Heaters.Repo`, keeping "I/O at the edges".
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Media.Clip

  # ---------------------------------------------------------------------------
  # CRUD Operations
  # ---------------------------------------------------------------------------

  @doc """
  Get a clip by ID.
  Returns {:ok, clip} if found, {:error, :not_found} otherwise.
  """
  @spec get_clip(integer()) :: {:ok, Clip.t()} | {:error, :not_found}
  def get_clip(id) do
    case Repo.get(Clip, id) do
      nil -> {:error, :not_found}
      clip -> {:ok, clip}
    end
  end

  @doc """
  Get a clip by ID with its associated artifacts preloaded.
  Returns {:ok, clip} if found, {:error, :not_found} otherwise.
  """
  @spec get_clip_with_artifacts(integer()) :: {:ok, Clip.t()} | {:error, :not_found}
  def get_clip_with_artifacts(id) do
    case Repo.get(Clip, id) do
      nil -> {:error, :not_found}
      clip -> {:ok, Repo.preload(clip, :clip_artifacts)}
    end
  end

  @doc """
  Get a clip by ID. Raises if not found.
  """
  @spec get_clip!(integer()) :: Clip.t()
  def get_clip!(id) do
    Repo.get!(Clip, id) |> Repo.preload([:source_video, :clip_artifacts])
  end

  @doc """
  Create a single clip and return it.
  """
  @spec create_clip(map()) :: {:ok, Clip.t()} | {:error, any()}
  def create_clip(clip_attrs) when is_map(clip_attrs) do
    %Clip{}
    |> Clip.changeset(clip_attrs)
    |> Repo.insert()
  end

  @doc """
  Returns a changeset for updating a clip with the given attributes.
  """
  @spec change_clip(Clip.t(), map()) :: Ecto.Changeset.t()
  def change_clip(%Clip{} = clip, attrs) do
    Clip.changeset(clip, attrs)
  end

  @doc """
  Update a clip with the given attributes.
  """
  @spec update_clip(Clip.t(), map()) :: {:ok, Clip.t()} | {:error, any()}
  def update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update([])
  end

  # ---------------------------------------------------------------------------
  # State Management
  # ---------------------------------------------------------------------------

  @doc """
  Update the ingest state of a clip.
  """
  @spec update_state(Clip.t(), String.t()) :: {:ok, Clip.t()} | {:error, any()}
  def update_state(%Clip{} = clip, new_state) do
    import Ecto.Changeset

    clip
    |> cast(%{ingest_state: new_state}, [:ingest_state])
    |> Repo.update([])
  end

  @doc """
  Mark a clip as failed with error tracking and retry count increment.
  """
  @spec mark_failed(Clip.t(), String.t(), String.t()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_failed(%Clip{} = clip, failure_state, error_message) do
    import Ecto.Changeset

    attrs = %{
      ingest_state: failure_state,
      last_error: error_message,
      retry_count: (clip.retry_count || 0) + 1
    }

    clip
    |> cast(attrs, [:ingest_state, :last_error, :retry_count])
    |> Repo.update([])
  end

  # ---------------------------------------------------------------------------
  # Bulk Operations
  # ---------------------------------------------------------------------------

  @doc """
  Create multiple clips from a list of attribute maps.
  Returns {count, clips} tuple.
  """
  @spec create_clips([map()]) :: {non_neg_integer(), [Clip.t()]}
  def create_clips(rows) when is_list(rows) do
    Repo.insert_all(Clip, rows, returning: true)
  end

  @doc """
  Batch update clips matching a queryable with the given updates.
  """
  @spec batch_update(Ecto.Queryable.t(), map()) :: {non_neg_integer(), any()}
  def batch_update(queryable, updates) do
    Repo.update_all(queryable, set: Enum.to_list(updates))
  end

  @doc """
  Create multiple clips with conflict handling for duplicate clip_filepath values.
  Uses INSERT...ON CONFLICT DO NOTHING to gracefully handle duplicate entries.
  """
  @spec create_clips_with_conflict_handling([map()]) :: {:ok, [Clip.t()]} | {:error, any()}
  def create_clips_with_conflict_handling(clips_attrs) when is_list(clips_attrs) do
    # Validate all clips before bulk insert
    validated_changesets = Enum.map(clips_attrs, &Clip.changeset(%Clip{}, &1))

    case validate_clip_changesets(validated_changesets) do
      :ok ->
        try do
          # Use ON CONFLICT DO NOTHING to handle duplicate clip_filepath gracefully
          {_count, clips} =
            Repo.insert_all(
              Clip,
              clips_attrs,
              returning: true,
              on_conflict: :nothing,
              conflict_target: :clip_filepath
            )

          {:ok, clips}
        rescue
          e -> {:error, Exception.message(e)}
        end

      {:error, errors} ->
        {:error, "Validation failed: #{format_clip_validation_errors(errors)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Query Functions - Pipeline State Management
  # ---------------------------------------------------------------------------

  @doc """
  Get all clips with the given ingest state.
  """
  @spec get_clips_by_state(String.t()) :: [Clip.t()]
  def get_clips_by_state(state) when is_binary(state) do
    from(c in Clip, where: c.ingest_state == ^state)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Query Functions - Identifier-Based Operations
  # ---------------------------------------------------------------------------

  @doc """
  Check if clips exist with the given identifiers.
  """
  @spec check_clips_exist_by_identifiers([String.t()]) :: {:ok, integer()} | {:error, any()}
  def check_clips_exist_by_identifiers(identifiers) when is_list(identifiers) do
    try do
      count =
        from(c in Clip, where: c.clip_identifier in ^identifiers)
        |> Repo.aggregate(:count, :id)

      {:ok, count}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Get clips by their identifiers.
  """
  @spec get_clips_by_identifiers([String.t()]) :: {:ok, [Clip.t()]} | {:error, any()}
  def get_clips_by_identifiers(identifiers) when is_list(identifiers) do
    try do
      clips =
        from(c in Clip, where: c.clip_identifier in ^identifiers)
        |> Repo.all()

      {:ok, clips}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Fetch clips by their identifiers.
  Used to retrieve existing clips when conflict handling indicates they already exist.
  """
  @spec fetch_clips_by_identifiers([String.t()]) :: {:ok, [Clip.t()]} | {:error, any()}
  def fetch_clips_by_identifiers(identifiers) when is_list(identifiers) do
    try do
      clips =
        from(c in Clip, where: c.clip_identifier in ^identifiers)
        |> Repo.all()

      {:ok, clips}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation Functions
  # ---------------------------------------------------------------------------

  @doc """
  Validate that a clip exists and return it if found.
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

  # ---------------------------------------------------------------------------
  # Private Helper Functions
  # ---------------------------------------------------------------------------

  @spec validate_clip_changesets([Ecto.Changeset.t()]) :: :ok | {:error, list()}
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

  @spec format_clip_validation_errors(list()) :: String.t()
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
