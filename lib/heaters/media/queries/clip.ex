defmodule Heaters.Media.Queries.Clip do
  @moduledoc """
  READ-ONLY query functions for clips.

  This module contains ONLY read operations (SELECT queries). All database writes
  should go through `Heaters.Media.Commands.Clip` to maintain proper CQRS separation.
  """

  import Ecto.Query, warn: false
  @repo_port Application.compile_env(:heaters, :repo_port, Heaters.Database.EctoAdapter)
  alias Heaters.Media.Clip

  @doc """
  Get all clips with the given ingest state.
  """
  def get_clips_by_state(state) when is_binary(state) do
    from(c in Clip, where: c.ingest_state == ^state)
    |> @repo_port.all()
  end

  @doc """
  Get all clips that need keyframe extraction (review_approved, keyframing, or keyframe_failed).
  This enables resumable processing of interrupted jobs.
  """
  def get_clips_needing_keyframes() do
    states = ["review_approved", "keyframing", "keyframe_failed"]

    from(c in Clip, where: c.ingest_state in ^states)
    |> @repo_port.all()
  end

  @doc """
  Get all clips that need embedding generation (keyframed, embedding, or embedding_failed).
  This enables resumable processing of interrupted jobs.
  """
  def get_clips_needing_embeddings() do
    states = ["keyframed", "embedding", "embedding_failed"]

    from(c in Clip, where: c.ingest_state in ^states)
    |> @repo_port.all()
  end

  @doc """
  Get a clip by ID.
  Returns {:ok, clip} if found, {:error, :not_found} otherwise.
  """
  def get_clip(id) do
    case @repo_port.get(Clip, id) do
      nil -> {:error, :not_found}
      clip -> {:ok, clip}
    end
  end

  @doc """
  Get a clip by ID with its associated artifacts preloaded.
  Returns {:ok, clip} if found, {:error, :not_found} otherwise.
  """
  def get_clip_with_artifacts(id) do
    case @repo_port.get(Clip, id) do
      nil -> {:error, :not_found}
      clip -> {:ok, @repo_port.preload(clip, :clip_artifacts)}
    end
  end

  @doc """
  Get a clip by ID. Raises if not found.
  """
  def get_clip!(id) do
    @repo_port.get!(Clip, id) |> @repo_port.preload([:source_video, :clip_artifacts])
  end

  @doc """
  Get all virtual clips that are ready for export (review_approved state).
  This enables the export worker to find approved virtual clips for final encoding.
  """
  def get_virtual_clips_ready_for_export() do
    from(c in Clip,
      where: c.is_virtual == true and c.ingest_state == "review_approved"
    )
    |> @repo_port.all()
  end

  @doc """
  Get all source videos that have approved virtual clips ready for export.
  This enables the pipeline dispatcher to find source videos with clips to export.
  """
  def get_source_videos_with_clips_ready_for_export() do
    from(c in Clip,
      where: c.is_virtual == true and c.ingest_state == "review_approved",
      select: c.source_video_id,
      distinct: true
    )
    |> @repo_port.all()
  end

  @doc "Fast count of clips still in `pending_review`."
  def pending_review_count do
    Clip
    |> where([c], c.ingest_state == "pending_review" and is_nil(c.reviewed_at))
    |> select([c], count("*"))
    |> @repo_port.one()
  end

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
end
