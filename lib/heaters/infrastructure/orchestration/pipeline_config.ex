defmodule Heaters.Infrastructure.Orchestration.PipelineConfig do
  @moduledoc """
  Declarative pipeline configuration for the Dispatcher.

  Defines the complete workflow as data rather than code, making it easy to:
  - See the entire pipeline flow at a glance
  - Add, remove, or reorder stages without touching control logic
  - Test pipeline configuration independently
  - Maintain consistent logging and error handling patterns

  Each stage is defined as a map with either:
  - `query` + `build` functions for database queries that enqueue jobs
  - `call` function for direct operations (like EventProcessor actions)

  The `label` field provides human-readable descriptions for logging.

  Pipeline Flow:
  videos needing ingest → videos needing splice → sprites → keyframes → embeddings → archive

  ## Resumable Processing

  The pipeline supports resumable processing of interrupted jobs across all stages:
  - **Ingest Stage**: Processes videos in "new", "downloading", or "download_failed" states
  - **Splice Stage**: Processes videos in "downloaded", "splicing", or "splicing_failed" states
  - **Sprite Stage**: Processes clips in "spliced", "generating_sprite", or "sprite_failed" states
  - **Keyframe Stage**: Processes clips in "review_approved", "keyframing", or "keyframe_failed" states
  - **Embedding Stage**: Processes clips in "keyframed", "embedding", or "embedding_failed" states

  When containers shut down mid-processing, work resumes automatically without manual intervention
  or data loss. This provides production-grade reliability for video processing workloads.

  ## Review Action States

  Review actions are handled directly in the UI with immediate execution:
  - review_approved → keyframes (continues through pipeline)
  - review_skipped → terminal state (preserved with sprite sheet)
  - review_archived → archive (cleanup)
  - merge/split actions → create new clips in spliced state (60-second undo buffer)
  - group actions → both clips advance to review_approved

  ## Sprite Generation for All Clips

  The pipeline ensures ALL clips get sprite sheets generated, regardless of origin:
  - **Original clips**: From video splice operations
  - **Merged clips**: From merge operations (60-second undo buffer)
  - **Split clips**: From split operations (60-second undo buffer)

  The "clips needing sprites" stage automatically processes any clip in "spliced" state,
  ensuring no clip enters review without a sprite sheet.
  """

  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Videos.Operations.Ingest.Worker, as: IngestWorker
  alias Heaters.Videos.Operations.Preprocessing.Worker, as: PreprocessingWorker
  alias Heaters.Videos.Operations.SceneDetection.Worker, as: SceneDetectionWorker
  alias Heaters.Videos.Operations.Splice.Worker, as: SpliceWorker
  alias Heaters.Clips.Operations.Artifacts.Sprite.Worker, as: SpriteWorker
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
      # Stage 1: Ingest (unchanged)
      %{
        label: "videos needing ingest → download",
        query: fn -> VideoQueries.get_videos_needing_ingest() end,
        build: fn video -> IngestWorker.new(%{source_video_id: video.id}) end
      },

      # Stage 2: NEW - Preprocessing (replaces part of splice workflow)
      %{
        label: "videos needing preprocessing → proxy generation",
        query: fn -> VideoQueries.get_videos_needing_preprocessing() end,
        build: fn video -> PreprocessingWorker.new(%{source_video_id: video.id}) end
      },

      # Stage 3: NEW - Scene detection for virtual clips (replaces sprite generation)
      %{
        label: "videos needing scene detection → virtual clips",
        query: fn -> VideoQueries.get_videos_needing_scene_detection() end,
        build: fn video -> SceneDetectionWorker.new(%{source_video_id: video.id}) end
      },

      # Stage 4: Legacy splice (keep temporarily during transition)
      %{
        label: "videos needing splice → splice",
        query: fn -> VideoQueries.get_videos_needing_splice() end,
        build: fn video -> SpliceWorker.new(%{source_video_id: video.id}) end
      },

      # Stage 5: Legacy sprite generation (keep temporarily during transition)
      %{
        label: "clips needing sprites → sprites",
        query: fn -> ClipQueries.get_clips_needing_sprites() end,
        build: fn clip -> SpriteWorker.new(%{clip_id: clip.id}) end
      },

      # Stage 6: Keyframes (will be updated for source-level keyframes later)
      %{
        label: "clips needing keyframes → keyframes",
        query: fn -> ClipQueries.get_clips_needing_keyframes() end,
        build: fn clip -> KeyframeWorker.new(%{clip_id: clip.id, strategy: "multi"}) end
      },

      # Stage 7: Embeddings (unchanged for now)
      %{
        label: "clips needing embeddings → embeddings",
        query: fn -> ClipQueries.get_clips_needing_embeddings() end,
        build: fn clip ->
          EmbeddingWorker.new(%{
            clip_id: clip.id,
            model_name: "openai/clip-vit-base-patch32",
            generation_strategy: "keyframe_multi_avg"
          })
        end
      },

            # Stage 8: NEW - Export (virtual clips → physical clips)
      %{
        label: "approved virtual clips → final encoding",
        query: fn ->
          # Get source video IDs that have approved virtual clips
          ClipQueries.get_source_videos_with_clips_ready_for_export()
          |> Enum.map(fn source_video_id -> %{id: source_video_id} end)
        end,
        build: fn source_video -> ExportWorker.new(%{source_video_id: source_video.id}) end
      },

      # Stage 9: Archive (unchanged)
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
