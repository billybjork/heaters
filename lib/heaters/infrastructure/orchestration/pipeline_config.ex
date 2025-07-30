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
  - `call` function for direct operations (like database maintenance tasks)

  The `label` field provides human-readable descriptions for logging.

  Enhanced Virtual Clips Pipeline Flow:
  download → preprocess → detect_scenes → finalize_cache → rolling_export → keyframes → embeddings → archive

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
  - Resource sharing optimizes master downloads
  - Clips become available immediately after export (no waiting for full batch)
  """

  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Videos.Download.Worker, as: DownloadWorker
  alias Heaters.Videos.Preprocess.Worker, as: PreprocessWorker
  alias Heaters.Videos.DetectScenes.Worker, as: DetectScenesWorker
  alias Heaters.Videos.FinalizeCache.Worker, as: FinalizeCacheWorker
  alias Heaters.Clips.Artifacts.Keyframe.Worker, as: KeyframeWorker
  alias Heaters.Clips.Embeddings.Worker, as: EmbeddingWorker
  alias Heaters.Clips.Archive.Worker, as: ArchiveWorker
  alias Heaters.Clips.Export.Worker, as: ExportWorker
  require Logger

  @doc """
  Returns the complete pipeline stage configuration.

  Each stage contains:
  - `label`: Human-readable description for logging
  - `query`: Function that returns items to process (for DB query stages)
  - `build`: Function that builds an Oban job from an item (for DB query stages)
  - `call`: Function to execute directly (for action stages)
  - `next_stage`: Optional configuration for direct job chaining (performance optimization)
  """
  @spec stages() :: [map()]
  def stages do
    [
      # Stage 1: Download (chains to preprocessing)
      %{
        label: "videos needing download",
        query: fn -> VideoQueries.get_videos_needing_ingest() end,
        build: fn video -> DownloadWorker.new(%{source_video_id: video.id}) end,
        next_stage: %{
          worker: PreprocessWorker,
          condition: fn source_video -> 
            source_video.ingest_state == "downloaded" and is_nil(source_video.proxy_filepath)
          end,
          args: fn source_video -> %{source_video_id: source_video.id} end
        }
      },

      # Stage 2: Preprocess (chains to scene detection)
      %{
        label: "videos needing preprocessing → proxy generation",
        query: fn -> VideoQueries.get_videos_needing_preprocessing() end,
        build: fn video -> PreprocessWorker.new(%{source_video_id: video.id}) end,
        next_stage: %{
          worker: DetectScenesWorker,
          condition: fn source_video ->
            source_video.ingest_state == "preprocessed" and 
            not is_nil(source_video.proxy_filepath) and
            source_video.needs_splicing == true
          end,
          args: fn source_video -> %{source_video_id: source_video.id} end
        }
      },

      # Stage 3: Scene detection (chains to cache finalization)
      %{
        label: "videos needing scene detection → virtual clips",
        query: fn -> VideoQueries.get_videos_needing_scene_detection() end,
        build: fn video -> DetectScenesWorker.new(%{source_video_id: video.id}) end,
        next_stage: %{
          worker: FinalizeCacheWorker,
          condition: fn source_video ->
            source_video.needs_splicing == false and 
            is_nil(source_video.cache_finalized_at) and
            (not is_nil(source_video.filepath) or 
             not is_nil(source_video.proxy_filepath) or
             not is_nil(source_video.master_filepath))
          end,
          args: fn source_video -> %{source_video_id: source_video.id} end
        }
      },

      # Stage 4: Cache finalization (no chaining - end of video processing)
      %{
        label: "videos needing cache finalization → S3 upload",
        query: fn -> VideoQueries.get_videos_needing_cache_finalization() end,
        build: fn video -> FinalizeCacheWorker.new(%{source_video_id: video.id}) end
        # No next_stage - this is the end of the video processing pipeline
      },

      # Stage 5: Rolling Export (virtual clips → physical clips)
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

      # Stage 6: Keyframes (operates on exported physical clips)
      %{
        label: "exported clips needing keyframes",
        query: fn -> ClipQueries.get_clips_needing_keyframes() end,
        build: fn clip -> KeyframeWorker.new(%{clip_id: clip.id, strategy: "multi"}) end
      },

      # Stage 7: Embeddings (operates on keyframed clips)
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

      # Stage 8: Archive (cleanup archived clips)
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

  @doc """
  Find the next stage configuration for a given worker.
  
  Returns the chaining configuration if the worker has a next stage defined.
  """
  @spec find_next_stage_for_worker(module()) :: {:ok, map()} | {:error, :not_found}
  def find_next_stage_for_worker(worker_module) do
    stages()
    |> Enum.find(fn stage ->
      case Map.get(stage, :build) do
        nil -> false
        build_fn ->
          # Check if this stage builds the given worker type
          # We'll use a sample item to test the build function
          sample_result = build_fn.(%{id: 0})
          sample_result.__struct__ == worker_module
      end
    end)
    |> case do
      %{next_stage: next_stage} -> {:ok, next_stage}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Execute job chaining for a worker if configured.
  
  This is the centralized chaining logic that workers can call.
  """
  @spec maybe_chain_next_job(module(), any()) :: :ok | {:error, any()}
  def maybe_chain_next_job(current_worker, item) do
    case find_next_stage_for_worker(current_worker) do
      {:ok, %{worker: next_worker, condition: condition_fn, args: args_fn}} ->
        if condition_fn.(item) do
          args = args_fn.(item)
          
          case next_worker.new(args) |> Oban.insert() do
            {:ok, _job} ->
              Logger.info("PipelineConfig: Chained #{inspect(current_worker)} → #{inspect(next_worker)} for item #{item.id}")
              :ok
              
            {:error, reason} ->
              Logger.warning("PipelineConfig: Failed to chain #{inspect(current_worker)} → #{inspect(next_worker)}: #{inspect(reason)}")
              {:error, reason}
          end
        else
          Logger.debug("PipelineConfig: Condition not met for chaining #{inspect(current_worker)}, skipping")
          :ok
        end
        
      {:error, :not_found} ->
        Logger.debug("PipelineConfig: No chaining configured for #{inspect(current_worker)}")
        :ok
    end
  end
end
