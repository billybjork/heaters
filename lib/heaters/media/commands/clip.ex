defmodule Heaters.Media.Commands.Clip do
  @moduledoc """
  WRITE-ONLY operations for `Heaters.Media.Clip`.

  This module contains ONLY write operations (INSERT, UPDATE, DELETE). All database reads
  should go through `Heaters.Media.Queries.Clip` to maintain proper CQRS separation.
  All DB interaction goes through `Heaters.Repo`, keeping
  "I/O at the edges".
  """

  alias Heaters.Repo
  alias Heaters.Media.{Clip, Queries}

  # ---------------------------------------------------------------------------
  # Basic state updates
  # ---------------------------------------------------------------------------

  @spec update_state(Clip.t(), String.t()) :: {:ok, Clip.t()} | {:error, any()}
  def update_state(%Clip{} = clip, new_state) do
    import Ecto.Changeset

    clip
    |> cast(%{ingest_state: new_state}, [:ingest_state])
    |> Repo.update([])
  end

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
  # Bulk helpers (create, update, etc.)  – minimal subset needed by pipeline
  # ---------------------------------------------------------------------------

  def create_clips(rows) when is_list(rows) do
    Repo.insert_all(Clip, rows, returning: true)
  end

  def batch_update(queryable, updates) do
    Repo.update_all(queryable, set: Enum.to_list(updates))
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

  @doc """
  Check if clips exist with the given identifiers.
  """
  @spec check_clips_exist_by_identifiers([String.t()]) :: {:ok, integer()} | {:error, any()}
  def check_clips_exist_by_identifiers(identifiers) when is_list(identifiers) do
    import Ecto.Query

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
    import Ecto.Query

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
    import Ecto.Query

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
  # Update operations
  # ---------------------------------------------------------------------------

  @doc """
  Returns a changeset for updating a clip with the given attributes.
  """
  def change_clip(%Clip{} = clip, attrs) do
    Clip.changeset(clip, attrs)
  end

  @doc """
  Update a clip with the given attributes.
  """
  def update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update([])
  end

  # ---------------------------------------------------------------------------
  # Read helpers (delegating to Queries for purity)
  # ---------------------------------------------------------------------------

  defdelegate get(id), to: Queries.Clip, as: :get_clip
  defdelegate get!(id), to: Queries.Clip, as: :get_clip!
  defdelegate get_with_artifacts(id), to: Queries.Clip, as: :get_clip_with_artifacts

  # ---------------------------------------------------------------------------
  # Private helper functions
  # ---------------------------------------------------------------------------

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
