defmodule Heaters.Pipeline.Config do
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
  download → preprocess → detect_scenes → upload_cache → rolling_export → keyframes → embeddings → archive

  ## Resumable Processing

  The pipeline supports resumable processing of interrupted jobs across all stages:
  - **Download Stage**: Processes videos in "new", "downloading", or "download_failed" states
  - **Preprocess Stage**: Processes videos in "downloaded", "preprocessing", or "preprocess_failed" states
  - **Scene Detection Stage**: Processes videos with proxy files needing virtual clip creation
  - **Cache Upload Stage**: Processes videos needing S3 upload and cache cleanup
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

  ## Job Chaining

  The pipeline supports direct job chaining for performance optimization:
  - Download → Preprocess (when download completes successfully)
  - Preprocess → Scene Detection (when preprocessing completes and splicing is needed)
  - Scene Detection → Cache Finalization (when scene detection completes)
  - Other stages use standard Oban job scheduling
  """

  alias Heaters.Media.Queries.Video, as: VideoQueries
  alias Heaters.Media.Queries.Clip, as: ClipQueries
  alias Heaters.Processing.Download.Worker, as: DownloadWorker
  alias Heaters.Processing.Preprocess.Worker, as: PreprocessWorker
  alias Heaters.Processing.DetectScenes.Worker, as: DetectScenesWorker
  alias Heaters.Storage.PipelineCache.UploadCache.Worker, as: UploadCacheWorker
  alias Heaters.Storage.Archive.Worker, as: ArchiveWorker
  alias Heaters.Processing.Keyframes.Worker, as: KeyframeWorker
  alias Heaters.Processing.Embeddings.Worker, as: EmbeddingWorker
  alias Heaters.Storage.Archive.Worker, as: ArchiveWorker
  alias Heaters.Processing.Render.Export.Worker, as: ExportWorker
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

      # Stage 3: Scene detection (chains to cache upload)
      %{
        label: "videos needing scene detection → virtual clips",
        query: fn -> VideoQueries.get_videos_needing_scene_detection() end,
        build: fn video -> DetectScenesWorker.new(%{source_video_id: video.id}) end,
        next_stage: %{
          worker: UploadCacheWorker,
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

      # Stage 4: Cache upload (no chaining - end of video processing)
      %{
        label: "videos needing cache upload → S3 upload",
        query: fn -> VideoQueries.get_videos_needing_cache_finalization() end,
        build: fn video -> UploadCacheWorker.new(%{source_video_id: video.id}) end
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
      ["videos needing download", "videos needing preprocessing → proxy generation", ...]
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
    # Create a mapping of workers to their stages for direct lookup
    worker_to_stage = %{
      Heaters.Processing.Download.Worker => "videos needing download",
      Heaters.Processing.Preprocess.Worker => "videos needing preprocessing → proxy generation",
      Heaters.Processing.DetectScenes.Worker => "videos needing scene detection → virtual clips",
      Heaters.Storage.PipelineCache.UploadCache.Worker =>
        "videos needing cache upload → S3 upload",
      Heaters.Processing.Render.Export.Worker => "approved virtual clips → rolling export",
      Heaters.Processing.Keyframes.Worker => "exported clips needing keyframes",
      Heaters.Processing.Embeddings.Worker => "keyframed clips needing embeddings",
      Heaters.Storage.Archive.Worker => "review_archived clips → archive"
    }

    target_stage_label = Map.get(worker_to_stage, worker_module)

    if target_stage_label do
      found_stage =
        stages()
        |> Enum.find(fn stage -> stage.label == target_stage_label end)

      case found_stage do
        %{next_stage: next_stage} ->
          {:ok, next_stage}

        %{} = _stage ->
          {:error, :not_found}

        nil ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
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
        condition_result = condition_fn.(item)

        if condition_result do
          args = args_fn.(item)

          # Direct chaining - call the worker immediately instead of enqueueing
          Task.start(fn ->
            Logger.info(
              "PipelineConfig: Chained #{inspect(current_worker)} → #{inspect(next_worker)} for item #{item.id}"
            )

            # Convert atom keys to string keys (Oban format)
            string_args = for {key, value} <- args, into: %{}, do: {to_string(key), value}
            next_worker.handle_work(string_args)
          end)

          :ok
        else
          :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end
end
