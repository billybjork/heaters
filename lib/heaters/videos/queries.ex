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
  Get all source videos that need splice processing (downloaded, splicing, or splicing_failed).
  This enables resumable processing of interrupted jobs.
  """
  def get_videos_needing_splice() do
    states = ["downloaded", "splicing", "splicing_failed"]

    from(s in SourceVideo, where: s.ingest_state in ^states)
    |> Repo.all()
  end
end
