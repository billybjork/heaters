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
  new → download → splice → sprites → keyframes → embeddings → archive

  Review Action States:
  - review_approved → keyframes (continues through pipeline)
  - review_skipped → terminal state (preserved with sprite sheet)
  - review_archived → archive (cleanup)
  - merge/split actions → create new clips in spliced state
  - group actions → both clips advance to review_approved

  Note: Review actions are handled directly in the UI with 60-second undo buffer
  for merge/split operations.
  """

  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Videos.Operations.Ingest.Worker, as: IngestWorker
  alias Heaters.Videos.Operations.Splice.Worker, as: SpliceWorker
  alias Heaters.Clips.Operations.Artifacts.Sprite.Worker, as: SpriteWorker
  alias Heaters.Clips.Operations.Artifacts.Keyframe.Worker, as: KeyframeWorker
  alias Heaters.Clips.Embeddings.Worker, as: EmbeddingWorker
  alias Heaters.Clips.Operations.Archive.Worker, as: ArchiveWorker

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
      %{
        label: "new videos → download",
        query: fn -> VideoQueries.get_videos_by_state("new") end,
        build: fn video -> IngestWorker.new(%{source_video_id: video.id}) end
      },
      %{
        label: "downloaded videos → splice",
        query: fn -> VideoQueries.get_videos_by_state("downloaded") end,
        build: fn video -> SpliceWorker.new(%{source_video_id: video.id}) end
      },
      %{
        label: "spliced clips → sprites",
        query: fn -> ClipQueries.get_clips_by_state("spliced") end,
        build: fn clip -> SpriteWorker.new(%{clip_id: clip.id}) end
      },
      %{
        label: "approved clips → keyframes",
        query: fn -> ClipQueries.get_clips_by_state("review_approved") end,
        build: fn clip -> KeyframeWorker.new(%{clip_id: clip.id, strategy: "multi"}) end
      },
      %{
        label: "keyframed clips → embeddings",
        query: fn -> ClipQueries.get_clips_by_state("keyframed") end,
        build: fn clip ->
          EmbeddingWorker.new(%{
            clip_id: clip.id,
            model_name: "clip-vit-base-patch32",
            generation_strategy: "multi"
          })
        end
      },
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
