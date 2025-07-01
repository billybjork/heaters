# Clip-Level Idempotency via Native Elixir Scene Detection

**Status:** Planned  
**Priority:** High  
**Estimated Effort:** 2-3 sprints  

## Problem Statement

The current SpliceWorker implementation has **subprocess reliability issues** that impact video processing:

### Current Architecture Issues
1. **Subprocess overhead**: Python interop via JSON creates parsing failures and communication bottlenecks
2. **All-or-nothing processing**: If any step fails after processing 20/25 clips, all work is lost
3. **No resumability**: Failures require complete re-processing (15+ minutes of wasted compute)
4. **JSON parsing brittleness**: Multi-line responses or formatting issues cause complete failures

### Real Example (2025-06-27)
- Python task: Successfully created 25 clips, uploaded to S3 ✅
- JSON parsing: Failed due to multi-line response format ❌  
- Database: 0 clip records created ❌
- Recovery: Must re-process entire video (15 minutes wasted)

## Proposed Solution: Native Elixir Scene Detection

### High-Level Approach
**Replace Python subprocess with native Elixir scene detection** using the **Evision library** (OpenCV-Elixir bindings), while maintaining all existing patterns and interfaces.

### Architecture Overview

#### Core Principles
1. **Native Elixir Processing**: Use Evision for all OpenCV operations (no Python subprocess)
2. **Maintain Existing Patterns**: Keep all current worker interfaces and state management
3. **Simple S3 Idempotency**: Check S3 existence before processing clips
4. **Gradual Migration**: Feature flag for safe rollout
5. **Zero Schema Changes**: Use existing database tables and state transitions

#### Refined Module Structure (Exactly Matching Existing Patterns)
```
# Business Logic Context (following keyframe.ex + keyframe/, merge.ex + merge/ pattern)
lib/heaters/videos/
├── operations/                        # NEW: I/O orchestration directory
│   ├── splice.ex                      # Main orchestration module (like keyframe.ex, merge.ex)
│   └── splice/                        # Domain logic directory (like keyframe/, merge/)
│       ├── scene_detector.ex          # Native Evision scene detection
│       ├── histogram.ex               # Histogram calculation utilities
│       └── comparison_methods.ex      # Threshold comparison methods
├── ingest.ex                          # EXISTING: State management 
├── queries.ex                         # EXISTING: Database queries
├── intake.ex                          # EXISTING: Video submission
└── source_video.ex                    # EXISTING: Schema

# Worker Integration (existing pattern)
lib/heaters/workers/videos/
└── splice_worker.ex                   # UPDATED: Use Operations.Splice.run_splice() instead of PyRunner

# Leverage existing shared utilities:
lib/heaters/clips/operations/shared/
├── ffmpeg_runner.ex                   # REUSE: Standardized FFmpeg operations
├── video_metadata.ex                  # REUSE: Video property extraction  
├── temp_manager.ex                    # REUSE: Temporary file handling
├── file_naming.ex                     # REUSE: S3 path generation
└── result_building.ex                 # REUSE: Structured result types

# Use existing infrastructure adapters:
lib/heaters/infrastructure/adapters/
├── s3_adapter.ex                      # REUSE: S3 operations
├── ffmpeg_adapter.ex                  # REUSE: FFmpeg operations
└── database_adapter.ex                # REUSE: Database operations
```

#### 1. Pure Domain Logic: Native Scene Detection
```elixir
defmodule Heaters.Videos.Operations.Splice.SceneDetector do
  @moduledoc """
  Pure domain logic for scene detection using Evision (OpenCV bindings).
  No I/O operations - accepts local file paths and returns scene data.
  Follows "I/O at the edges" architecture principle.
  """
  
  alias Evision, as: CV
  alias Heaters.Videos.Operations.Splice.{Histogram, ComparisonMethods}
  
  @type scene :: %{
    start_frame: non_neg_integer(),
    end_frame: non_neg_integer(),
    start_time_seconds: float(),
    end_time_seconds: float()
  }
  
  @type detection_result :: %{
    scenes: [scene()],
    video_info: map(),
    detection_params: map()
  }
  
  @spec detect_scenes(String.t(), keyword()) :: {:ok, detection_result()} | {:error, any()}
  def detect_scenes(video_path, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.6)
    method = Keyword.get(opts, :method, :correl)
    min_duration = Keyword.get(opts, :min_duration_seconds, 1.0)
    
    with {:ok, cap} <- CV.VideoCapture.videoCapture(video_path),
         {:ok, video_info} <- extract_video_properties(cap),
         {:ok, scene_cuts} <- analyze_frames_for_cuts(cap, threshold, method),
         :ok <- CV.VideoCapture.release(cap) do
      
      scenes = build_scenes_from_cuts(scene_cuts, video_info.fps, min_duration)
      
      {:ok, %{
        scenes: scenes,
        video_info: video_info,
        detection_params: %{threshold: threshold, method: method, min_duration: min_duration}
      }}
    else
      error -> error
    end
  end
  
  defp analyze_frames_for_cuts(cap, threshold, method) do
    # Stream-based processing for memory efficiency
    cut_frames = [0] # Always start with frame 0
    
    case process_video_stream(cap, threshold, method, cut_frames) do
      {:ok, final_cuts} -> {:ok, final_cuts}
      error -> error
    end
  end
  
  defp process_video_stream(cap, threshold, method, cut_frames, prev_hist \\ nil, frame_num \\ 0) do
    case CV.VideoCapture.read(cap) do
      {true, frame} ->
        current_hist = Histogram.calculate_bgr_histogram(frame)
        
        updated_cuts = 
          case prev_hist do
            nil -> cut_frames
            _ ->
              score = CV.compareHist(prev_hist, current_hist, ComparisonMethods.get_method(method))
              
              if ComparisonMethods.is_scene_cut?(score, threshold, method) do
                [frame_num | cut_frames]
              else
                cut_frames
              end
          end
        
        process_video_stream(cap, threshold, method, updated_cuts, current_hist, frame_num + 1)
      
      {false, _} ->
        # End of video - add final frame
        final_cuts = [frame_num | cut_frames] |> Enum.reverse() |> Enum.uniq()
        {:ok, final_cuts}
      
      error ->
        {:error, "Failed to read frame #{frame_num}: #{inspect(error)}"}
    end
  end
  
  defp build_scenes_from_cuts(cut_frames, fps, min_duration) do
    cut_frames
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [start_frame, end_frame] ->
      start_time = start_frame / fps
      end_time = end_frame / fps
      duration = end_time - start_time
      
      %{
        start_frame: start_frame,
        end_frame: end_frame,
        start_time_seconds: start_time,
        end_time_seconds: end_time,
        duration_seconds: duration
      }
    end)
    |> Enum.filter(fn scene -> scene.duration_seconds >= min_duration end)
  end
end
```

#### 2. I/O Orchestration: Native Splice Operations  
```elixir
defmodule Heaters.Videos.Operations.Splice do
  @moduledoc """
  I/O orchestration for the splice workflow using native Elixir scene detection.
  Replaces splice.py functionality while following "I/O at the edges" architecture.
  Integrates with existing Ingest state management and shared utilities.
  """
  
  alias Heaters.Videos.Operations.Splice.SceneDetector
  alias Heaters.Videos.{Ingest, SourceVideo}
  alias Heaters.Infrastructure.Adapters.{S3Adapter, FFmpegAdapter}
  alias Heaters.Clips.Operations.Shared.{TempManager, FileNaming, ResultBuilding, FFmpegRunner}
  require Logger
  
  @type splice_result :: %{
    status: :success | :error,
    clips_data: [map()] | nil,
    metadata: map(),
    error: String.t() | nil
  }
  
  @spec run_splice(SourceVideo.t(), keyword()) :: splice_result()
  def run_splice(%SourceVideo{} = source_video, opts \\ []) do
    Logger.info("Starting native splice for source_video_id: #{source_video.id}")
    
    # Use existing temp manager for file handling
    TempManager.with_temp_dir(fn temp_dir ->
      perform_splice_workflow(source_video, temp_dir, opts)
    end)
  end
  
  defp perform_splice_workflow(source_video, temp_dir, opts) do
    with {:ok, local_video_path} <- download_source_video(source_video, temp_dir),
         {:ok, detection_result} <- run_scene_detection(local_video_path, opts),
         {:ok, clips_data} <- process_scenes_to_clips(source_video, detection_result, temp_dir) do
      
      ResultBuilding.build_success_result(%{
        clips: clips_data,
        total_scenes_detected: length(detection_result.scenes),
        clips_created: length(clips_data),
        detection_params: detection_result.detection_params,
        video_properties: detection_result.video_info
      })
    else
      {:error, reason} -> 
        Logger.error("Splice workflow failed: #{inspect(reason)}")
        ResultBuilding.build_error_result(reason)
    end
  end
  
  defp download_source_video(%SourceVideo{filepath: s3_key} = source_video, temp_dir) do
    local_path = Path.join(temp_dir, "source_video.mp4")
    
    Logger.info("Downloading source video from S3: #{s3_key}")
    
    case S3Adapter.download_file(s3_key, local_path) do
      :ok -> {:ok, local_path}
      {:error, reason} -> {:error, "Failed to download source video: #{inspect(reason)}"}
    end
  end
  
  defp run_scene_detection(video_path, opts) do
    detection_opts = [
      threshold: Keyword.get(opts, :threshold, 0.3),
      method: Keyword.get(opts, :method, :correl),
      min_duration_seconds: Keyword.get(opts, :min_duration_seconds, 1.0)
    ]
    
    Logger.info("Running scene detection with opts: #{inspect(detection_opts)}")
    
    case SceneDetector.detect_scenes(video_path, detection_opts) do
      {:ok, result} ->
        Logger.info("Scene detection completed: #{length(result.scenes)} scenes found")
        {:ok, result}
      
      {:error, reason} ->
        {:error, "Scene detection failed: #{inspect(reason)}"}
    end
  end
  
  defp process_scenes_to_clips(source_video, detection_result, temp_dir) do
    # Use existing file naming utilities for S3 paths
    clips_s3_prefix = Ingest.build_s3_prefix(source_video)
    
    clips_data = 
      detection_result.scenes
      |> Enum.with_index(1)
      |> Enum.map(fn {scene, index} ->
        process_single_scene(source_video, scene, index, clips_s3_prefix, temp_dir)
      end)
    
    # Check for any errors in clip processing
    case Enum.find(clips_data, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(clips_data, fn {:ok, clip_data} -> clip_data end)}
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp process_single_scene(source_video, scene, index, clips_s3_prefix, temp_dir) do
    clip_identifier = "#{source_video.id}_clip_#{String.pad_leading("#{index}", 3, "0")}"
    local_clip_path = Path.join(temp_dir, "#{clip_identifier}.mp4")
    s3_clip_key = "#{clips_s3_prefix}/#{clip_identifier}.mp4"
    
    # Check if clip already exists in S3 (idempotency)
    case S3Adapter.head_object(s3_clip_key) do
      {:ok, _} ->
        Logger.info("Clip #{clip_identifier} already exists in S3, skipping extraction")
        build_clip_data_from_existing(clip_identifier, s3_clip_key, scene)
      
      {:error, :not_found} ->
        extract_and_upload_clip(source_video, scene, clip_identifier, local_clip_path, s3_clip_key, temp_dir)
      
      {:error, reason} ->
        {:error, "Failed to check S3 existence for #{s3_clip_key}: #{inspect(reason)}"}
    end
  end
  
  defp extract_and_upload_clip(source_video, scene, clip_identifier, local_clip_path, s3_clip_key, temp_dir) do
    source_video_path = Path.join(temp_dir, "source_video.mp4")
    
    with {:ok, _file_size} <- FFmpegRunner.create_video_clip(
           source_video_path,
           local_clip_path,
           scene.start_time_seconds,
           scene.end_time_seconds
         ),
         :ok <- S3Adapter.upload_file(local_clip_path, s3_clip_key) do
      
      Logger.info("Successfully created and uploaded clip: #{clip_identifier}")
      build_clip_data(clip_identifier, s3_clip_key, scene)
    else
      {:error, reason} ->
        {:error, "Failed to extract/upload clip #{clip_identifier}: #{inspect(reason)}"}
    end
  end
  
  defp build_clip_data(clip_identifier, s3_clip_key, scene) do
    {:ok, %{
      clip_identifier: clip_identifier,
      clip_filepath: s3_clip_key,
      start_frame: scene.start_frame,
      end_frame: scene.end_frame,
      start_time_seconds: Float.round(scene.start_time_seconds, 3),
      end_time_seconds: Float.round(scene.end_time_seconds, 3),
      metadata: %{
        duration_seconds: Float.round(scene.duration_seconds, 3),
        scene_index: scene.start_frame
      }
    }}
  end
  
  defp build_clip_data_from_existing(clip_identifier, s3_clip_key, scene) do
    {:ok, %{
      clip_identifier: clip_identifier,
      clip_filepath: s3_clip_key,
      start_frame: scene.start_frame,
      end_frame: scene.end_frame,
      start_time_seconds: Float.round(scene.start_time_seconds, 3),
      end_time_seconds: Float.round(scene.end_time_seconds, 3),
      metadata: %{
        duration_seconds: Float.round(scene.duration_seconds, 3),
        scene_index: scene.start_frame,
        skipped: true,
        reason: "already_exists_in_s3"
      }
    }}
  end
end
```

#### 3. Updated SpliceWorker Integration
```elixir
defmodule Heaters.Workers.Videos.SpliceWorker do
  @moduledoc """
  Updated SpliceWorker that uses native Elixir scene detection instead of Python subprocess.
  Maintains exact same interface and patterns for seamless integration with existing pipeline.
  """
  use Heaters.Workers.GenericWorker, queue: :media_processing

  alias Heaters.Videos.{Ingest, SourceVideo, Operations}
  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Workers.Clips.SpriteWorker
  require Logger

  @splicing_complete_states ["spliced", "splicing_failed"]

  @impl Heaters.Workers.GenericWorker
  def handle(%{"source_video_id" => source_video_id}) do
    Logger.info("SpliceWorker: Starting native splice for source_video_id: #{source_video_id}")

    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      handle_splicing(source_video)
    else
      {:error, :not_found} ->
        Logger.warning("SpliceWorker: Source video #{source_video_id} not found")
        :ok
    end
  end

  defp handle_splicing(%SourceVideo{ingest_state: state} = source_video)
       when state in @splicing_complete_states do
    Logger.info(
      "SpliceWorker: Source video #{source_video.id} already in state '#{state}', skipping"
    )
    
    :ok
  end

  defp handle_splicing(%SourceVideo{ingest_state: "splicing"} = source_video) do
    Logger.info(
      "SpliceWorker: Source video #{source_video.id} already in 'splicing' state, proceeding with native splice"
    )

    run_native_splice_task(source_video)
  end

  defp handle_splicing(source_video) do
    # Use existing state management pattern from Ingest module
    case Ingest.start_splicing(source_video.id) do
      {:ok, updated_video} ->
        run_native_splice_task(updated_video)

      {:error, reason} ->
        Logger.error("SpliceWorker: Failed to transition to splicing state: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_native_splice_task(source_video) do
    Logger.info("SpliceWorker: Running native Elixir splice for source_video_id: #{source_video.id}")

    splice_opts = [
      threshold: 0.3,
      method: :correl,
      min_duration_seconds: 1.0
    ]

    case Operations.Splice.run_splice(source_video, splice_opts) do
      %{status: :success, clips_data: clips_data} when is_list(clips_data) ->
        Logger.info(
          "SpliceWorker: Successfully processed #{length(clips_data)} clips with native Elixir"
        )

        process_splice_results(source_video, clips_data)

      %{status: :error, error: error_message} ->
        Logger.error("SpliceWorker: Native splice failed: #{error_message}")
        mark_splicing_failed(source_video, error_message)

      unexpected_result ->
        error_message = "Native splice returned unexpected result: #{inspect(unexpected_result)}"
        Logger.error("SpliceWorker: #{error_message}")
        mark_splicing_failed(source_video, error_message)
    end
  end

  defp process_splice_results(source_video, clips_data) do
    # Use existing validation and processing pipeline
    case Ingest.validate_clips_data(clips_data) do
      :ok ->
        case Ingest.create_clips_from_splice(source_video.id, clips_data) do
          {:ok, clips} ->
            case Ingest.complete_splicing(source_video.id) do
              {:ok, _final_video} ->
                # Store clips for enqueue_next/1 (maintains existing pattern)
                Process.put(:clips, clips)
                :ok

              {:error, reason} ->
                Logger.error("SpliceWorker: Failed to mark splicing complete: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("SpliceWorker: Failed to create clips: #{inspect(reason)}")
            mark_splicing_failed(source_video, reason)
        end

      {:error, validation_error} ->
        Logger.error("SpliceWorker: Invalid clips data: #{validation_error}")
        mark_splicing_failed(source_video, validation_error)
    end
  end



  defp mark_splicing_failed(source_video, reason) do
    case Ingest.mark_failed(source_video, "splicing_failed", reason) do
      {:ok, _} ->
        {:error, reason}

      {:error, db_error} ->
        Logger.error("SpliceWorker: Failed to mark video as failed: #{inspect(db_error)}")
        {:error, reason}
    end
  end

  @impl Heaters.Workers.GenericWorker
  def enqueue_next(_args) do
    # Maintain exact same enqueue_next pattern for pipeline compatibility
    case Process.get(:clips) do
      clips when is_list(clips) ->
        jobs =
          clips
          |> Enum.map(fn clip ->
            SpriteWorker.new(%{clip_id: clip.id})
          end)

        case Oban.insert_all(jobs) do
          inserted_jobs when is_list(inserted_jobs) and length(inserted_jobs) > 0 ->
            Logger.info("SpliceWorker: Enqueued #{length(inserted_jobs)} sprite workers")
            :ok

          error ->
            Logger.error("SpliceWorker: Failed to enqueue sprite workers: #{inspect(error)}")
            {:error, "Failed to enqueue sprite workers"}
        end

      _ ->
        Logger.info("SpliceWorker: No clips found to enqueue sprite workers")
        :ok
    end
  end
end
```

#### 4. Simple S3 Idempotency
The updated SpliceWorker will include basic S3 existence checking within the main `Operations.Splice.run_splice()` function:

```elixir
# In Operations.Splice module
defp process_single_scene(source_video, scene, index, clips_s3_prefix, temp_dir) do
  s3_clip_key = "#{clips_s3_prefix}/#{clip_identifier}.mp4"
  
  # Simple idempotency check - skip if already exists in S3
  case S3Adapter.head_object(s3_clip_key) do
    {:ok, _} ->
      Logger.info("Clip #{clip_identifier} already exists in S3, skipping extraction")
      build_clip_data_from_existing(clip_identifier, s3_clip_key, scene)
    
    {:error, :not_found} ->
      extract_and_upload_clip(source_video, scene, clip_identifier, local_clip_path, s3_clip_key, temp_dir)
      
    {:error, reason} ->
      {:error, "Failed to check S3 existence for #{s3_clip_key}: #{inspect(reason)}"}
  end
end
```

This provides sufficient idempotency for the initial implementation without over-engineering.

### Database Schema Analysis

#### ✅ Current Schema Already Perfect
After analyzing existing migrations and state management, **no database changes are needed**:

**source_videos table** already has:
- `ingest_state` with transitions: `new` → `downloading` → `downloaded` → `splicing` → `spliced` 
- `spliced_at` timestamp field
- `filepath` field for S3 storage

**clips table** already has:
- `ingest_state` field (clips start in `"spliced"` state)
- `clip_filepath` field for S3 paths  
- All timing fields: `start_time_seconds`, `end_time_seconds`, `start_frame`, `end_frame`

**Current workflow** already implements proper state transitions via `Ingest` module functions.

### Key Technical Advantages

#### Reliability Benefits
- **Eliminate subprocess failures**: No Python process spawning or JSON parsing errors
- **S3-based idempotency**: Use `S3Adapter.head_object/1` to skip clips that already exist in S3 storage
- **Type safety**: Compile-time guarantees with `SpliceResult` structs vs. runtime JSON parsing errors
- **Simpler error handling**: Native Elixir error patterns instead of subprocess debugging

#### Performance Benefits  
- **Remove serialization overhead**: Direct OpenCV operations without JSON round-trips
- **Memory efficiency**: Streaming video processing without loading entire files into memory
- **Native binary operations**: Evision uses NIFs for high-performance OpenCV integration

#### Developer Experience Benefits
- **Single language**: Eliminate Python/Elixir context switching
- **Pattern matching**: Robust error handling with Elixir's `with` constructs
- **Maintain existing patterns**: No changes to worker interfaces or state management
- **Hot code reloading**: Update scene detection logic without restarting workers

### Architecture Benefits

#### Simple Idempotency
- **S3 existence checking**: Skip clips that already exist in S3 storage
- **Efficient retries**: Avoid reprocessing clips that completed successfully  
- **Maintain existing workflow**: Use current `Ingest` module state management
- **Zero breaking changes**: Keep all existing worker and pipeline interfaces

#### Integration Benefits
- **Leverage existing utilities**: Reuse `TempManager`, `FFmpegRunner`, `S3Adapter` (including new `head_object/1`)
- **Follow established patterns**: Match `keyframe.ex` + `keyframe/` structure with `SpliceResult` types
- **Preserve orchestration**: No changes to pipeline config or dispatcher
- **Maintain compatibility**: Existing tests and monitoring continue to work
- **Feature flag safety**: Gradual rollout with instant rollback capability

### Implementation Plan

#### Phase 1: Foundation & Dependencies (Week 1)
1. **Add Evision dependency** - Add to `mix.exs` and test compilation in Docker environment
2. **Add S3 head_object function** - Implement `S3Adapter.head_object/1` for idempotency checking
3. **Create SpliceResult type** - Add to `Types` module to match existing result patterns
4. **Add feature flag configuration** - Setup for gradual rollout (`config :heaters, :use_native_splice`)
5. **Create module structure** - `operations/splice.ex` + `operations/splice/` directory
6. **Basic scene detection proof-of-concept** - Simple histogram-based detection using Evision

#### Phase 2: Core Scene Detection Implementation (Week 2)  
1. **Port Python OpenCV logic** - Frame-by-frame histogram comparison using Evision
2. **Create domain modules** - `SceneDetector`, `Histogram`, `ComparisonMethods` (pure business logic)
3. **Memory-efficient processing** - Streaming approach for large files
4. **Unit tests for accuracy** - Compare results with Python implementation
5. **Integration with existing utilities** - Use `TempManager`, `S3Adapter`, `FFmpegRunner`

#### Phase 3: I/O Orchestration & Integration (Week 3)
1. **Complete `Operations.Splice` module** - Full workflow orchestration with `SpliceResult` types
2. **S3 idempotency logic** - Use `S3Adapter.head_object/1` to check S3 existence before processing clips
3. **Update SpliceWorker** - Replace `PyRunner.run()` with `Operations.Splice.run_splice()` using feature flag
4. **Maintain existing interfaces** - Keep `enqueue_next/1` and worker patterns unchanged
5. **Integration testing** - End-to-end workflow validation with existing pipeline

#### Phase 4: Production Readiness & Cleanup (Week 4)
1. **Performance optimization** - Memory usage and processing speed optimization
2. **Remove Python dependencies** - Delete `py/tasks/splice.py` and PyRunner integration
3. **Error handling refinement** - Better diagnostics and logging using existing patterns
4. **Documentation updates** - Architecture and operational guides
5. **Load testing** - Various video sizes and processing scenarios
6. **Remove feature flag** - After successful rollout and validation

### Migration Strategy

#### Simple Feature Flag Approach
- **Feature flag**: `config :heaters, :use_native_splice, true/false`
- **Zero database changes**: Use existing tables and state transitions
- **API preservation**: No breaking changes to worker interfaces
- **S3 idempotency**: Use `S3Adapter.head_object/1` for clip existence checking
- **Result types**: Use `SpliceResult` struct matching existing patterns

#### Rollback Plan
- **Instant rollback**: Toggle feature flag to disable native processing
- **No data migration**: All processing uses existing database schema
- **Process continuity**: In-flight clips complete normally

### Monitoring & Observability

#### Key Metrics to Track
- **Processing speed**: Clips/minute processing rate with native Elixir
- **Error rates**: Failure percentage and types of errors
- **S3 idempotency**: Number of clips skipped due to existing S3 files
- **Memory usage**: Peak memory consumption during processing

#### Logging Improvements
- **Native Elixir logging**: Better structured logs without subprocess noise
- **Scene detection metrics**: Number of scenes detected per video
- **S3 operation tracking**: Upload/download success rates
- **Processing time breakdown**: Time spent in each phase of the workflow

### Future Enhancements

#### Processing Improvements
- **GPU acceleration**: Leverage CUDA support in Evision for faster scene detection
- **Adaptive thresholds**: Dynamic scene detection parameters based on video content
- **Smart batching**: Process multiple clips concurrently within same worker

#### Developer Experience  
- **Hot reloading**: Update scene detection parameters without restart
- **Visual debugging**: Frame-by-frame histogram visualization
- **A/B testing**: Compare detection methods side-by-side

---

## Summary: Simplified Architecture Approach

### Key Findings from Architecture Analysis

**Zero Database Changes Needed**: Current schema already supports all required functionality with proper state transitions and S3 file management.

**Existing Patterns Are Perfect**: The `keyframe.ex` + `keyframe/` pattern provides the exact template for implementing `splice.ex` + `splice/` structure.

**State Management Already Exists**: The `Ingest` module already has all necessary functions (`start_splicing/1`, `complete_splicing/1`, `create_clips_from_splice/2`).

**Pipeline Integration Is Simple**: SpliceWorker is triggered by IngestWorker completion, requires no pipeline config changes.

### Core Benefits Delivered

1. **Eliminates subprocess reliability issues** - No more JSON parsing failures or Python interop problems  
2. **Simple S3-based idempotency** - Skip clips that already exist in S3 storage
3. **Maintains all existing patterns** - Zero breaking changes to worker interfaces or state management
4. **Memory efficiency** - Native Elixir processing without subprocess serialization overhead
5. **Complete Python elimination** - Remove Python subprocess dependency entirely

### Implementation Reality

This approach is much simpler than initially conceived:

**What We Actually Need:**
- Add Evision dependency to `mix.exs` and test Docker compilation
- Add `S3Adapter.head_object/1` function for S3 existence checking
- Create `SpliceResult` type in `Types` module to match existing patterns
- Create `operations/splice.ex` + `operations/splice/` directory structure  
- Port Python OpenCV logic to Evision (OpenCV-Elixir bindings)
- Update `SpliceWorker` to call `Operations.Splice.run_splice()` instead of `PyRunner.run()`
- Add feature flag configuration for safe rollout

**What We Don't Need:**
- Database schema changes (current schema is perfect)
- New state management (existing `Ingest` module has everything)
- Pipeline config changes (dispatcher doesn't trigger SpliceWorker)
- Complex supervision trees (existing worker patterns are sufficient)
- Python fallback logic (complete elimination of Python dependency)

**Architecture Consistency:**
- Exactly matches `keyframe.ex` + `keyframe/` and `merge.ex` + `merge/` patterns
- Uses existing shared utilities (`TempManager`, `S3Adapter`, `FFmpegRunner`)  
- Integrates with existing infrastructure adapters
- Maintains all current worker interfaces and behaviors

**Next Steps:**
1. **Add Evision dependency**: Add to `mix.exs` and test compilation in Docker environment
2. **Add S3 head_object function**: Implement `S3Adapter.head_object/1` for idempotency checking
3. **Create SpliceResult type**: Add to `Types` module to match existing result patterns
4. **Add feature flag**: Setup configuration for gradual rollout
5. **Create module structure**: Set up `operations/splice.ex` + `operations/splice/` directory structure  
6. **Proof of concept**: Implement basic scene detection using Evision histogram comparison
7. **Update SpliceWorker**: Replace `PyRunner.run()` call with native `Operations.Splice.run_splice()`

**Key Implementation Notes:**
- **Zero database changes**: Use existing schema and state management from `Ingest` module
- **Zero pipeline changes**: SpliceWorker triggered by IngestWorker, not dispatcher
- **Maintain interfaces**: Keep all existing worker patterns (`GenericWorker`, `enqueue_next/1`)
- **S3 idempotency**: Use `S3Adapter.head_object/1` to check S3 file existence before processing clips
- **Result types**: Use `SpliceResult` struct matching existing `KeyframeResult` patterns
- **Feature flag safety**: Gradual rollout with instant rollback capability
- **Complete Python elimination**: Remove `py/tasks/splice.py` and PyRunner integration

**Risk Assessment:**
- **Low risk**: No database changes, existing patterns maintained, feature flag for safety
- **High reward**: Eliminates subprocess JSON parsing failures and improves reliability
- **Main dependencies**: 
  - Evision compilation in Docker environment
  - S3 head_object function implementation
  - SpliceResult type integration with existing patterns 