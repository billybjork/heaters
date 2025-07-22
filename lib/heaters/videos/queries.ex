defmodule Heaters.Videos.Queries do
  @moduledoc """
  Query functions for source videos.
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Videos.SourceVideo

  @doc """
  Get a source video by ID. Returns {:ok, source_video} if found, {:error, :not_found} otherwise.
  """
  def get_source_video(id) do
    case Repo.get(SourceVideo, id) do
      nil -> {:error, :not_found}
      source_video -> {:ok, source_video}
    end
  end

  @doc """
  Get all source videos with the given ingest state.
  """
  def get_videos_by_state(state) when is_binary(state) do
    from(s in SourceVideo, where: s.ingest_state == ^state)
    |> Repo.all()
  end

  @doc """
  Get all source videos that need ingest processing (new, downloading, or download_failed).
  This enables resumable processing of interrupted jobs.
  """
  def get_videos_needing_ingest() do
    states = ["new", "downloading", "download_failed"]

    from(s in SourceVideo, where: s.ingest_state in ^states)
    |> Repo.all()
  end

  @doc """
  Get all source videos that need preprocessing (downloaded without proxy_filepath).
  This enables resumable processing of interrupted jobs.
  """
  def get_videos_needing_preprocessing() do
    from(s in SourceVideo,
      where: s.ingest_state == "downloaded" and is_nil(s.proxy_filepath))
    |> Repo.all()
  end

  @doc """
  Get all source videos that need scene detection (preprocessed with needs_splicing = true).
  This enables resumable processing of interrupted jobs.
  """
  def get_videos_needing_scene_detection() do
    from(s in SourceVideo,
      where: not is_nil(s.proxy_filepath) and s.needs_splicing == true)
    |> Repo.all()
  end

  @doc """
  Get all source videos that need splice processing (downloaded, splicing, or splicing_failed).
  This enables resumable processing of interrupted jobs.
  """
  def get_videos_needing_splice() do
    # Legacy splice workflow - only process videos that haven't entered the new preprocessing workflow
    # Videos with proxy_filepath are in the new workflow and should be handled by SceneDetection instead
    states = ["downloaded", "splicing", "splicing_failed"]

    from(s in SourceVideo, 
      where: s.ingest_state in ^states and is_nil(s.proxy_filepath))
    |> Repo.all()
  end
end
