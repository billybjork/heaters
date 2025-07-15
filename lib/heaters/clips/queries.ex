defmodule Heaters.Clips.Queries do
  @moduledoc """
  Query functions for clips.
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Clips.Clip

  @doc """
  Get all clips with the given ingest state.
  """
  def get_clips_by_state(state) when is_binary(state) do
    from(c in Clip, where: c.ingest_state == ^state)
    |> Repo.all()
  end

  @doc """
  Get all clips that need sprite generation (spliced, generating_sprite, or sprite_failed).
  This enables resumable processing of interrupted jobs.
  """
  def get_clips_needing_sprites() do
    states = ["spliced", "generating_sprite", "sprite_failed"]

    from(c in Clip, where: c.ingest_state in ^states)
    |> Repo.all()
  end

  @doc """
  Get all clips that need keyframe extraction (review_approved, keyframing, or keyframe_failed).
  This enables resumable processing of interrupted jobs.
  """
  def get_clips_needing_keyframes() do
    states = ["review_approved", "keyframing", "keyframe_failed"]

    from(c in Clip, where: c.ingest_state in ^states)
    |> Repo.all()
  end

  @doc """
  Get all clips that need embedding generation (keyframed, embedding, or embedding_failed).
  This enables resumable processing of interrupted jobs.
  """
  def get_clips_needing_embeddings() do
    states = ["keyframed", "embedding", "embedding_failed"]

    from(c in Clip, where: c.ingest_state in ^states)
    |> Repo.all()
  end

  @doc """
  Get a clip by ID.
  Returns {:ok, clip} if found, {:error, :not_found} otherwise.
  """
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
  def get_clip_with_artifacts(id) do
    case Repo.get(Clip, id) |> Repo.preload(:clip_artifacts) do
      nil -> {:error, :not_found}
      clip -> {:ok, clip}
    end
  end

  @doc """
  Get a clip by ID. Raises if not found.
  """
  def get_clip!(id) do
    Repo.get!(Clip, id) |> Repo.preload([:source_video, :clip_artifacts])
  end

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
    |> Repo.update()
  end

  @doc "Fast count of clips still in `pending_review`."
  def pending_review_count do
    Clip
    |> where([c], c.ingest_state == "pending_review" and is_nil(c.reviewed_at))
    |> select([c], count("*"))
    |> Repo.one()
  end
end
