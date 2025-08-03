defmodule Heaters.Media.Queries.Video do
  @moduledoc """
  READ-ONLY query functions for source videos.

  This module contains ONLY read operations (SELECT queries). All database writes
  should go through `Heaters.Media.Commands.Video` to maintain proper CQRS separation.
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Media.Video

  @doc """
  Get a source video by ID. Returns {:ok, source_video} if found, {:error, :not_found} otherwise.
  """
  def get_source_video(id) do
    case Repo.get(Video, id) do
      nil -> {:error, :not_found}
      source_video -> {:ok, source_video}
    end
  end

  @doc """
  Get all source videos with the given ingest state.
  """
  def get_videos_by_state(state) when is_binary(state) do
    from(s in Video, where: s.ingest_state == ^state)
    |> Repo.all()
  end

  @doc """
  Get all source videos that need ingest processing (new, downloading, or download_failed).
  This enables resumable processing of interrupted jobs.
  """
  def get_videos_needing_ingest() do
    states = ["new", "downloading", "download_failed"]

    from(s in Video, where: s.ingest_state in ^states)
    |> Repo.all()
  end

  @doc """
  Get all source videos that need preprocessing (downloaded without proxy_filepath).
  This enables resumable processing of interrupted jobs.
  """
  def get_videos_needing_preprocessing() do
    from(s in Video,
      where: s.ingest_state == "downloaded" and is_nil(s.proxy_filepath)
    )
    |> Repo.all()
  end

  @doc """
  Get all source videos that need scene detection (preprocessed with needs_splicing = true).
  This enables resumable processing of interrupted jobs.
  """
  def get_videos_needing_scene_detection() do
    from(s in Video,
      where: not is_nil(s.proxy_filepath) and s.needs_splicing == true
    )
    |> Repo.all()
  end

  @doc """
  Get all source videos that need cache finalization.

  Videos need cache finalization if:
  - Scene detection is complete (needs_splicing = false)
  - Cache has not been finalized yet (cache_finalized_at is null)
  - Has files that might be cached (has filepath, proxy_filepath, or master_filepath)
  """
  def get_videos_needing_cache_finalization() do
    from(s in Video,
      where:
        s.needs_splicing == false and
          is_nil(s.cache_finalized_at) and
          (not is_nil(s.filepath) or not is_nil(s.proxy_filepath) or not is_nil(s.master_filepath))
    )
    |> Repo.all()
  end
end
