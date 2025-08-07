defmodule Heaters.Pipeline.Queries do
  @moduledoc """
  Pipeline orchestration queries for finding clips and videos that need processing.

  This module contains queries used exclusively by the pipeline orchestration system
  to discover work that needs to be done. These are NOT domain operations on clips
  themselves, but rather infrastructure queries for pipeline stage discovery.

  ## When to Add Functions Here

  - **Pipeline stage discovery**: Finding clips/videos ready for the next processing step
  - **Orchestration queries**: Used by `Pipeline.Config` or `Pipeline.Dispatcher`
  - **Cross-stage queries**: Queries that span multiple processing stages
  - **Resumable processing**: Finding work that was interrupted and needs to resume

  ## When NOT to Add Functions Here

  - **Domain operations**: Core clip CRUD, state management, validation → `Media.Clips`
  - **Review workflow**: Queue management, review counts → `Review.Queue`
  - **Single-stage queries**: Queries specific to one processing module → that module

  All functions in this module should be used by pipeline orchestration code,
  not by domain business logic.
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Media.Clip
  alias Heaters.Media.Video

  # ---------------------------------------------------------------------------
  # Video Processing Pipeline Queries
  # ---------------------------------------------------------------------------

  @doc """
  Get all source videos that need ingest processing (new, downloading, or download_failed).

  This enables resumable processing of interrupted download jobs and is used by
  the pipeline dispatcher to find videos ready for download processing.

  ## Pipeline Usage
  Used by `Pipeline.Config` stage discovery for video ingest processing.
  """
  @spec get_videos_needing_ingest() :: [Video.t()]
  def get_videos_needing_ingest() do
    states = ["new", "downloading", "download_failed"]

    from(s in Video, where: s.ingest_state in ^states)
    |> Repo.all()
  end

  @doc """
  Get all source videos that need preprocessing (downloaded without proxy_filepath).

  This enables resumable processing of interrupted preprocessing jobs and is used by
  the pipeline dispatcher to find videos ready for preprocessing.

  ## Pipeline Usage
  Used by `Pipeline.Config` stage discovery for video preprocessing.
  """
  @spec get_videos_needing_preprocessing() :: [Video.t()]
  def get_videos_needing_preprocessing() do
    from(s in Video,
      where:
        (s.ingest_state == :downloaded or s.ingest_state == :preprocessing or
           s.ingest_state == :preprocessing_failed) and
          is_nil(s.proxy_filepath)
    )
    |> Repo.all()
  end

  @doc """
  Get all source videos that need scene detection (preprocessed with needs_splicing = true).

  This enables resumable processing of interrupted scene detection jobs and is used by
  the pipeline dispatcher to find videos ready for scene detection.

  ## Pipeline Usage
  Used by `Pipeline.Config` stage discovery for scene detection processing.
  """
  @spec get_videos_needing_scene_detection() :: [Video.t()]
  def get_videos_needing_scene_detection() do
    from(s in Video,
      where: not is_nil(s.proxy_filepath) and s.needs_splicing == true
    )
    |> Repo.all()
  end

  @doc """
  Get all source videos that need cache persistence.

  Videos need cache persistence if:
  - Scene detection is complete (needs_splicing = false)
  - Cache has not been persisted yet (cache_persisted_at is null)
  - Has files that might be cached (has filepath, proxy_filepath, or master_filepath)

  ## Pipeline Usage
  Used by `Pipeline.Config` stage discovery for cache persistence processing.
  """
  @spec get_videos_needing_cache_persistence() :: [Video.t()]
  def get_videos_needing_cache_persistence() do
    from(s in Video,
      where:
        s.needs_splicing == false and
          is_nil(s.cache_persisted_at) and
          (not is_nil(s.filepath) or not is_nil(s.proxy_filepath) or not is_nil(s.master_filepath))
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Clip Export Processing Queries
  # ---------------------------------------------------------------------------

  @doc """
  Get all virtual clips that are ready for export (review_approved state).

  This enables the export pipeline to find approved virtual clips for final encoding.
  Used by rolling export to discover work that needs to be done.

  ## Pipeline Usage
  Used by `Pipeline.Config` stage discovery for export processing.
  """
  @spec get_virtual_clips_ready_for_export() :: [Clip.t()]
  def get_virtual_clips_ready_for_export() do
    from(c in Clip,
      where: is_nil(c.clip_filepath) and c.ingest_state == :review_approved
    )
    |> Repo.all()
  end

  @doc """
  Get all source videos that have approved virtual clips ready for export.

  This enables the pipeline dispatcher to find source videos with clips to export
  for batch processing optimization.

  ## Pipeline Usage
  Used by `Pipeline.Config` for source video-based export batching.
  """
  @spec get_source_videos_with_clips_ready_for_export() :: [integer()]
  def get_source_videos_with_clips_ready_for_export() do
    from(c in Clip,
      where: is_nil(c.clip_filepath) and c.ingest_state == :review_approved,
      select: c.source_video_id,
      distinct: true
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Keyframe Processing Queries
  # ---------------------------------------------------------------------------

  @doc """
  Get all clips that need keyframe extraction (review_approved, keyframing, or keyframe_failed).

  This enables resumable processing of interrupted keyframe jobs and is used by
  the pipeline dispatcher to find clips ready for keyframe extraction.

  ## Pipeline Usage
  Used by `Pipeline.Config` stage discovery for keyframe processing.
  """
  @spec get_clips_needing_keyframes() :: [Clip.t()]
  def get_clips_needing_keyframes() do
    states = ["review_approved", "keyframing", "keyframe_failed"]

    from(c in Clip, where: c.ingest_state in ^states)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Embedding Processing Queries
  # ---------------------------------------------------------------------------

  @doc """
  Get all clips that need embedding generation (keyframed, embedding, or embedding_failed).

  This enables resumable processing of interrupted embedding jobs and is used by
  the pipeline dispatcher to find clips ready for embedding generation.

  ## Pipeline Usage
  Used by `Pipeline.Config` stage discovery for embedding processing.
  """
  @spec get_clips_needing_embeddings() :: [Clip.t()]
  def get_clips_needing_embeddings() do
    states = ["keyframed", "embedding", "embedding_failed"]

    from(c in Clip, where: c.ingest_state in ^states)
    |> Repo.all()
  end
end
