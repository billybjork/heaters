defmodule Heaters.Infrastructure.Orchestration.PipelineConfig do
  @moduledoc """
  Declarative pipeline configuration for the Enhanced Virtual Clips workflow.

  Defines the complete workflow as data rather than code, making it easy to:
  - See the entire pipeline flow at a glance
  - Add, remove, or reorder stages without touching control logic
  - Test pipeline configuration independently
  - Maintain consistent logging and error handling patterns

  Each stage is defined as a map with either:
  - `query` + `build` functions for database queries that enqueue jobs
  - `call` function for direct operations (like EventProcessor actions)

  The `label` field provides human-readable descriptions for logging.

  Enhanced Virtual Clips Pipeline Flow:
  download → preprocess → detect_scenes → rolling_export → keyframes → embeddings → archive

  ## Resumable Processing

  The pipeline supports resumable processing of interrupted jobs across all stages:
  - **Download Stage**: Processes videos in "new", "downloading", or "download_failed" states
  - **Preprocess Stage**: Processes videos in "downloaded", "preprocessing", or "preprocess_failed" states
  - **Scene Detection Stage**: Processes videos with proxy files needing virtual clip creation
  - **Export Stage**: Processes approved virtual clips for rolling export to physical clips
  - **Keyframe Stage**: Processes exported clips in "exported", "keyframing", or "keyframe_failed" states
  - **Embedding Stage**: Processes clips in "keyframed", "embedding", or "embedding_failed" states

  When containers shut down mid-processing, work resumes automatically without manual intervention
  or data loss. This provides production-grade reliability for video processing workloads.

  ## Virtual Clip Review Actions

  Review actions are handled directly in the UI with instant cut point operations:
  - review_approved → rolling export (continues through pipeline)
  - review_skipped → terminal state
  - review_archived → archive (cleanup)
  - cut point operations → instant database updates (add/remove/move cuts)
  - group actions → both clips advance to review_approved

  ## Rolling Export Architecture

  The pipeline uses individual clip export rather than batch processing:
  - Each approved virtual clip gets its own export job
  - Resource sharing optimizes gold master downloads
  - Clips become available immediately after export (no waiting for full batch)
  """

  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Videos.Operations.Download.Worker, as: DownloadWorker
  alias Heaters.Videos.Operations.Preprocess.Worker, as: PreprocessWorker
  alias Heaters.Videos.Operations.DetectScenes.Worker, as: DetectScenesWorker
  alias Heaters.Clips.Operations.Artifacts.Keyframe.Worker, as: KeyframeWorker
  alias Heaters.Clips.Embeddings.Worker, as: EmbeddingWorker
  alias Heaters.Clips.Operations.Archive.Worker, as: ArchiveWorker
  alias Heaters.Clips.Operations.Export.Worker, as: ExportWorker

  @doc """
  Returns the complete pipeline stage configuration.

  Each stage contains:
  - `label`: Human-readable description for logging
  - `query`: Function that returns items to process (for DB query stages)
  - `build`: Function that builds an Oban job from an item (for DB query stages)
  - `call`: Function to execute directly (for action stages)
  """
  @spec stages() :: [map()]
  def stages do
    [
      # Stage 1: Download (unchanged)
      %{
        label: "videos needing download",
        query: fn -> VideoQueries.get_videos_needing_ingest() end,
        build: fn video -> DownloadWorker.new(%{source_video_id: video.id}) end
      },

      # Stage 2: Preprocess (creates gold master + review proxy)
      %{
        label: "videos needing preprocessing → proxy generation",
        query: fn -> VideoQueries.get_videos_needing_preprocessing() end,
        build: fn video -> PreprocessWorker.new(%{source_video_id: video.id}) end
      },

      # Stage 3: Scene detection (creates virtual clips)
      %{
        label: "videos needing scene detection → virtual clips",
        query: fn -> VideoQueries.get_videos_needing_scene_detection() end,
        build: fn video -> DetectScenesWorker.new(%{source_video_id: video.id}) end
      },

      # Stage 4: Rolling Export (virtual clips → physical clips)
      %{
        label: "approved virtual clips → rolling export",
        query: fn -> ClipQueries.get_virtual_clips_ready_for_export() end,
        build: fn clip -> 
          ExportWorker.new(%{
            clip_id: clip.id,
            source_video_id: clip.source_video_id
          })
        end
      },

      # Stage 5: Keyframes (operates on exported physical clips)
      %{
        label: "exported clips needing keyframes",
        query: fn -> ClipQueries.get_clips_needing_keyframes() end,
        build: fn clip -> KeyframeWorker.new(%{clip_id: clip.id, strategy: "multi"}) end
      },

      # Stage 6: Embeddings (operates on keyframed clips)
      %{
        label: "keyframed clips needing embeddings",
        query: fn -> ClipQueries.get_clips_needing_embeddings() end,
        build: fn clip ->
          EmbeddingWorker.new(%{
            clip_id: clip.id,
            model_name: "openai/clip-vit-base-patch32",
            generation_strategy: "keyframe_multi_avg"
          })
        end
      },

      # Stage 7: Archive (cleanup archived clips)
      %{
        label: "review_archived clips → archive",
        query: fn -> ClipQueries.get_clips_by_state("review_archived") end,
        build: fn clip -> ArchiveWorker.new(%{clip_id: clip.id}) end
      }
    ]
  end

  @doc """
  Returns just the stage labels for debugging/inspection.

  ## Examples

      iex> PipelineConfig.stage_labels()
      ["new videos → ingest", "spliced clips → sprites", "review actions", ...]
  """
  @spec stage_labels() :: [String.t()]
  def stage_labels do
    Enum.map(stages(), & &1.label)
  end

  @doc """
  Returns the number of configured pipeline stages.
  """
  @spec stage_count() :: non_neg_integer()
  def stage_count, do: length(stages())
end
