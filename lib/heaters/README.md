# Heaters Video Processing Pipeline

## Overview

Heaters processes videos through a **virtual clip pipeline**: download → proxy generation → virtual clips → human review → final export → embedding. The system emphasizes functional architecture with "I/O at the edges", direct action execution with buffer-time undo, and **hybrid processing** combining Elixir orchestration with Python (CV/ML/media processing) for optimal performance and reliability.

### Virtual Clip Architecture

The system uses a **virtual clip workflow** that eliminates re-encoding during review:

1. **Universal Download**: Single pathway for both web-scraped shows and user-uploaded clips
2. **Proxy Generation**: Creates lossless gold master (FFV1/MKV) + review proxy (all-I-frame H.264) 
3. **Virtual Clips**: Database records with cut points, no physical files until final export
4. **Instant Review**: WebCodecs-based seeking with instant merge/split operations
5. **Final Export**: High-quality encoding from gold master only after review approval

**Key Benefits**: Zero re-encoding during review, lossless quality preservation, instant operations, universal workflow.

### Technology Stack
- **Backend**: Elixir/Phoenix with LiveView
- **Database**: PostgreSQL with pgvector extension
- **Scene Detection**: Python OpenCV via PyRunner port communication
- **Keyframe Extraction**: Native Elixir FFmpeg implementation
- **ML Processing**: Python with PyTorch, Transformers
- **Media Processing**: Python with yt-dlp, FFmpeg, Rust (rambo for sprite generation)
- **Storage**: AWS S3 with idempotent operations and robust error handling
- **Background Jobs**: Oban with PostgreSQL and idempotent worker patterns

## Architecture Principles

- **Functional Domain Modeling**: "I/O at the edges" with pure business logic separated from I/O operations
- **Semantic Organization**: Clear distinction between user **Edits** (review actions) and automated **Artifacts** (pipeline stages)
- **Direct Action Execution**: Human review actions execute immediately with 60-second undo buffer for complex operations
- **Structured Results**: Type-safe Result structs with rich metadata and performance timing
- **Centralized Worker Behavior**: Standardized Oban worker patterns with shared lifecycle management, error handling, and idempotent state validation
- **Hybrid Processing**: Native Elixir for performance-critical operations (scene detection), Python for ML/media processing
- **Robust Error Handling**: Graceful degradation with comprehensive logging and state recovery

## State Flow

### Virtual Clip Pipeline

```
Source Video: new → downloading → downloaded → preprocess → preprocessed → detect_scenes → virtual clips created
                      ↓              ↓              ↓              ↓                ↓
               download_failed  (resumable)  preprocess_failed  (resumable)  detect_scenes_failed
                      ↑                          ↑                              ↑
                      └──────────────────────────┼──────────────────────────────┘
                                 ↓
                          (resumable processing)

Virtual Clips: pending_review → review_approved → exporting → exported (physical) → keyframing → keyframed → embedding → embedded
                    ↓                ↓              ↓            ↓              ↓           ↓           ↓
            review_skipped    review_archived   export_failed  (resumable)  keyframe_failed  (resumable) embedding_failed
                    ↓                ↓              ↑                           ↑                              ↑
             (terminal state)   archive → cleanup  └─────┬─────────────────────┘                              │
                                     ↑                   ↓                                                    │
                                     │           (resumable processing)                                       │
                              merge/split → new virtual clips → pending_review                               │
                              (instant DB ops)           ↓                                                   │
                                     ↑                   └─────────────┬───────────────────────────────────────┘
                                     └─────────────────────────────────┘
                                                    (resumable processing)
```

### Legacy Pipeline (Transitional)

```
Source Video: downloaded → splicing → spliced (physical clips)
Clips: spliced → generating_sprite → pending_review → review_approved → keyframing → embedding
```

## Key Design Decisions

### Semantic Operations Organization

The `Clips` context is organized by **operation type**, not file type:

- **`edits/`**: User actions that create new clips and enter review workflow
  - `Merge`, `Split` operations (write to `clips` table)
- **`artifacts/`**: Pipeline stages that generate supplementary data  
  - `Sprite`, `Keyframe`, `ClipArtifact` operations (write to `clip_artifacts` table)
- **`archive/`**: Cleanup operations for archived clips
  - `Archive` worker (S3 deletion and database cleanup)

This reflects the fundamental difference between human review actions and automated processing stages.

### Quality-First Download Architecture

The download pipeline implements a **quality-first download strategy** with intelligent fallback to ensure optimal video quality while maintaining reliability:

#### Primary Download Strategy (Best Quality)
- **Format**: `'bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b'`
- **Approach**: Downloads highest quality separate video/audio streams
- **yt-dlp Merge**: Internally merges streams using FFmpeg for maximum quality
- **Challenge**: Merge operation sometimes fails or produces corrupted files
- **Solution**: **Conditional normalization** applies lightweight FFmpeg re-encoding to fix merge issues

#### Fallback Download Strategy (Compatibility)
- **Format**: `'bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best'`
- **Approach**: Downloads pre-merged or more compatible formats
- **Benefit**: No merge operation needed, highly reliable
- **Trade-off**: May not achieve maximum possible quality

#### Conditional Normalization Logic
```python
# CRITICAL: This step preserves the best-quality-first approach
if download_method == 'primary' and requires_normalization:
    # Apply lightweight normalization to fix yt-dlp merge issues
    # Uses fast settings: -preset fast -crf 23 -movflags +faststart
    # Different from preprocess.py - just ensures valid MP4
    normalize_video(original_download, normalized_output)
else:
    # Fallback downloads don't need normalization
    use_original_download()
```

#### Architecture Benefits
- **Quality Preservation**: Gets best possible quality when available
- **Reliability**: Graceful fallback when quality approach fails  
- **Separation of Concerns**: Lightweight download fix vs. full preprocess pipeline
- **Performance**: Only normalizes when necessary (primary downloads)
- **Documentation**: Extensive comments prevent accidental removal of quality logic

This architecture ensures we maintain the **best quality first** principle while providing robust fallback mechanisms for challenging video sources.

### Direct Action Execution with Buffer Time

Human review actions execute immediately with undo support:
- **Simple Actions**: `approve`, `skip`, `archive`, `group` execute immediately
- **Complex Actions**: `merge`, `split` use 60-second buffer via Oban scheduling
- **Undo Support**: Cancels pending jobs and resets clip states within buffer window
- **Benefits**: Immediate feedback, reliable Oban job management, flexible undo

### Functional Architecture with "I/O at the Edges"

Operations follow Domain Modeling Made Functional principles:

```
Pure Domain Logic (testable, no I/O)
    ↓
I/O Orchestration (Operations modules - database operations, state coordination)
    ↓  
Infrastructure Adapters (S3, FFmpeg, Python - external I/O)
```

**I/O Layer Responsibilities**:
- **Operations modules**: Database operations (Repo calls), state transitions, business workflow coordination
- **Infrastructure adapters**: External I/O isolation (S3, FFmpeg, Python subprocess calls)

**Benefits**: Testable business logic, predictable functions, clear separation of concerns.

### Hybrid Processing Architecture

The system uses a **hybrid approach** combining native Elixir and Python processing, and balances architectural purity with practical efficiency:

#### Python Scene Detection
- **Technology**: Python OpenCV via PyRunner port communication for robust scene detection
- **Benefits**: Leverages mature Python OpenCV ecosystem with reliable scene detection algorithms
- **Implementation**: `Videos.DetectScenes` with Python task execution via PyRunner
- **Idempotency**: S3-based scene detection caching and clip existence checking prevents reprocessing

#### Native Elixir Keyframe Extraction
- **Technology**: Native Elixir FFmpeg implementation for high-performance keyframe extraction
- **Benefits**: Eliminates subprocess overhead and JSON parsing for better performance
- **Implementation**: `Clips.Artifacts.Keyframe` with direct FFmpeg calls via `Infrastructure.FFmpegAdapter`
- **Configuration**: Supports percentage-based and tag-based keyframe extraction strategies

#### Python ML/Media Processing
- **Technology**: Python for ML embedding generation and media processing
- **Benefits**: Leverages mature ML ecosystems and specialized media libraries
- **Interface**: Pure functions with structured JSON responses, no database access
- **Rust Integration**: Uses `rambo` binary for efficient sprite generation
- **Modular Design**: Complex tasks split into focused modules for maintainability (e.g., `media_processing.py`, `download_handler.py`, `s3_handler.py`)
- **Progress Reporting**: Real-time FFmpeg transcoding progress via PyRunner integration

```python
# Python tasks remain pure media processing functions
def run_task_name(explicit_params, **kwargs) -> dict:
    # Pure media processing - no DB connections
    # Return structured JSON for Elixir processing
```

#### Hybrid Optimization Pattern

**Split Operations** demonstrate the hybrid optimization pattern:
- **Pure Clip-Relative Approach**: Uses 1-indexed clip-relative frames throughout for simplicity and consistency
- **Frame-Time Conversion**: Converts clip-relative frames to clip-relative timestamps for FFmpeg operations
- **FPS Consistency**: Uses same FPS calculation logic as sprite metadata to ensure frontend/backend frame range consistency
- **I/O Efficiency**: Works directly with clip files, avoiding multi-gigabyte source video downloads
- **Idempotent Operations**: Database-level conflict handling and S3 cleanup ordering prevent partial failures
- **Benefits**: Maintains architectural purity while providing optimal performance and reliability

### Structured Result Types

All operations return type-safe structs with `@enforce_keys`:

```elixir
%SpriteResult{status: "success", clip_id: 123, artifacts: [...], duration_ms: 1500}
%KeyframeResult{status: "success", keyframe_count: 8, strategy: "uniform"}
%MergeResult{status: "success", merged_clip_id: 456, cleanup: %{...}}
%SpliceResult{status: "success", clips_data: [...], total_scenes_detected: 25}
%SplitResult{status: "success", new_clip_ids: [789, 790], cleanup: %{original_file_deleted: true}}
```

**Benefits**: Compile-time validation, rich metadata, direct field access without defensive `Map.get`.

### Centralized Worker Behavior

All workers use `Infrastructure.Orchestration.WorkerBehavior` which provides:

```elixir
defmodule MyWorker do
  use Heaters.Infrastructure.Orchestration.WorkerBehavior, queue: :media_processing
  
  @impl WorkerBehavior
  def handle_work(args) do
    # Pure business logic - infrastructure handled by behavior
  end
end
```

**Benefits**: 
- Automatic performance monitoring and structured logging
- Consistent error handling with comprehensive stack traces
- Standardized idempotency patterns (`check_complete_states`, `check_artifact_exists`)
- Common helpers for resource not found and already processed scenarios
- Zero boilerplate - workers focus purely on business logic

### Idempotent Worker Patterns

All workers implement robust idempotency patterns:
- **State Validation**: Check current state before processing to prevent duplicate work
- **Graceful Degradation**: Handle partial failures and retry scenarios
- **Resource Cleanup**: Ensure proper cleanup of temporary files and S3 objects
- **Error Recovery**: Comprehensive error handling with detailed logging

### Idempotent Operations and Transactional Reliability

All workers implement robust idempotency patterns for production reliability:
- **State Validation**: Check current state before processing to prevent duplicate work
- **Graceful Degradation**: Handle partial failures and retry scenarios with comprehensive error recovery
- **Database-First Approach**: Perform database operations before irreversible S3 cleanup to prevent data loss
- **Conflict Resolution**: Database-level unique constraint handling using `INSERT...ON CONFLICT DO NOTHING`
- **Resource Cleanup**: Proper cleanup of temporary files and S3 objects with transaction ordering
- **Error Recovery**: Comprehensive error handling with detailed logging for debugging

**Split Operations** demonstrate advanced transactional patterns:
- Database records created before S3 file deletion (prevents orphaned state)
- Idempotency checks detect already-completed operations
- Graceful handling of file-not-found scenarios when retrying interrupted operations
- Worker behavior handles `:already_processed` errors without failing jobs

### Virtual Clip Database Schema

The virtual clip architecture introduces key schema changes:

#### Source Videos Table
- **`needs_splicing`**: Boolean flag controlling scene detection workflow  
- **`proxy_filepath`**: S3 path to all-I-frame H.264 review proxy
- **`gold_master_filepath`**: S3 path to lossless FFV1/MKV archival master
- **`keyframe_offsets`**: JSONB array of byte positions for WebCodecs seeking

#### Clips Table  
- **`is_virtual`**: Boolean distinguishing virtual (cut points only) vs physical (file) clips
- **`cut_points`**: JSONB with `{start_frame, end_frame, start_time_seconds, end_time_seconds}`
- **`clip_filepath`**: Nullable when `is_virtual = true`, required when `is_virtual = false`
- **Constraint**: `CHECK (is_virtual = true OR clip_filepath IS NOT NULL)`

#### Migration Strategy
- **Graceful Transition**: Both virtual and legacy pipelines run concurrently
- **Data Integrity**: Database constraints ensure clip files exist when marked as physical
- **Backward Compatibility**: Existing physical clips continue to work unchanged

### Resumable Processing Architecture

The system provides comprehensive resumable processing to handle container restarts and interruptions:

- **Container Restart Resilience**: If containers shut down mid-processing, work resumes automatically when restarted
- **No Manual Intervention**: Interrupted jobs are detected and resumed without operator action
- **State-Based Recovery**: Each worker can handle items in intermediate states (downloading, splicing, generating_sprite, etc.)
- **Temporary File Cleanup**: Orphaned temporary files from previous runs are cleaned up on application startup
- **Progress Preservation**: Partial work is not lost and doesn't need to be repeated

**Resumable States by Stage**:
- **Download**: `new`, `downloading`, `download_failed`
- **Splice**: `downloaded`, `splicing`, `splicing_failed`
- **Sprite**: `spliced`, `generating_sprite`, `sprite_failed`
- **Keyframe**: `review_approved`, `keyframing`, `keyframe_failed`
- **Embedding**: `keyframed`, `embedding`, `embedding_failed`
- **Archive**: `review_archived`

This architecture ensures maximum reliability in production environments where container restarts are common.

## Workflow Examples

### Virtual Clip Pipeline

#### Video Download & Preprocessing
1. `Videos.submit/1` creates source video in `new` state
2. `Videos.Download.Worker` downloads/processes → `downloaded` state  
3. `Videos.Preprocess.Worker` creates gold master + review proxy → `preprocessed` state
   - **Gold Master**: Lossless FFV1/MKV for final export quality
   - **Review Proxy**: All-I-frame H.264 for efficient WebCodecs seeking
   - **Keyframe Offsets**: Byte positions for frame-perfect seeking

#### Scene Detection & Virtual Clips
1. `Videos.DetectScenes.Worker` runs **Python scene detection** on proxy → virtual clips in `pending_review` state
2. Virtual clips contain cut points (database only), no physical files created
3. Scene detection uses proxy file for speed while preserving cut point accuracy

#### Review Workflow
1. **WebCodecs Player**: Direct frame seeking on review proxy using keyframe offsets
2. Human reviews virtual clips and takes actions:
   - **approve** → `review_approved` (ready for export)
   - **skip** → `review_skipped` (terminal state)
   - **archive** → `review_archived` (cleanup via archive worker)
   - **group** → both clips → `review_approved` with `grouped_with_clip_id` metadata
   - **merge/split** → **instant database operations** update cut points → new virtual clips
3. Actions execute immediately with database transactions, no file re-encoding

#### Export & Post-Processing
1. `Clips.Export.Worker` encodes approved virtual clips from gold master → physical clips in `exported` state
2. `Clips.Artifacts.Keyframe.Worker` extracts keyframes → `keyframed` state
3. `Clips.Embeddings.Worker` generates ML embeddings → `embedded` state (final)

### Legacy Workflow (Transitional)
1. `Videos.Splice.Worker` runs scene detection → physical clips in `spliced` state
2. `Clips.Artifacts.Sprite.Worker` generates sprites → clips in `pending_review` state  
3. Traditional review workflow with sprite-based navigation

### Archive Workflow
1. `Clips.Archive.Worker` safely deletes S3 objects and database records
2. Robust S3 deletion handling for both XML and JSON responses
3. Proper cleanup of all associated artifacts and metadata

## Orchestration: Fully Declarative Pipeline

**`Infrastructure.Orchestration.Dispatcher`** implements a **fully declarative pipeline** using data-driven configuration:

```elixir
PipelineConfig.stages()
|> Enum.each(&run_stage/1)
```

Each stage is pure configuration:
- **Database Query Stages**: `query` function finds work, `build` function creates jobs
- **Action Stages**: `call` function executes direct operations (database maintenance)
- **Declarative Flow**: All state transitions handled by pipeline, not workers

**`Infrastructure.Orchestration.PipelineConfig`** provides complete workflow as data:

#### Virtual Clip Pipeline
1. `new videos → download` (DownloadWorker)
2. `downloaded videos → preprocess` (PreprocessWorker)
3. `preprocessed videos → detect_scenes` (DetectScenesWorker) ← **Creates virtual clips**
4. `approved virtual clips → export` (ExportWorker) ← **Batch export from gold master**
5. `exported clips → keyframes` (KeyframeWorker)
6. `keyframed clips → embeddings` (EmbeddingWorker)
7. `archived clips → archive` (ArchiveWorker)

#### Legacy Pipeline (Transitional)
- `downloaded videos → splice` (SpliceWorker) 
- `spliced clips → sprites` (SpriteWorker) ← **Handles ALL spliced clips (original, merged, and split)**

**Review Actions** are handled directly in the UI with immediate execution:
- Simple actions (approve/skip/archive/group) update states immediately
- Complex actions (merge/split) use 60-second Oban scheduling for undo support

### Key Architectural Decision: Single Source of Truth

**Before**: Mixed imperative/declarative approach with workers directly enqueueing other workers
- SpliceWorker → SpriteWorker (imperative)
- MergeWorker → SpriteWorker (imperative) 
- SplitWorker → SpriteWorker (imperative)

**After**: Fully declarative pipeline with single source of truth
- ALL workers focus purely on domain logic and state transitions
- Pipeline dispatcher handles ALL enqueueing based on database state
- "spliced clips → sprites" stage automatically catches clips from splice, merge, AND split operations
- **Critical**: ALL clips (original, merged, split) get sprite sheets generated before review
- Zero direct worker-to-worker communication

**Benefits**: Single source of truth, easier testing, clearer workflow visibility, separation of concerns between business logic and orchestration.

## Context Responsibilities

### Virtual Clip Architecture

- **`Videos`**: Source video lifecycle from submission through virtual clips creation
  - **`Videos.Download`**: Video download and processing workflow
  - **`Videos.Preprocess`**: Gold master + review proxy generation with keyframe offsets
  - **`Videos.DetectScenes`**: Python scene detection creating virtual clips (database records only)
- **`Clips`**: Clip transformations and state management (semantic Edits/Artifacts/Export organization)
  - **`Clips.VirtualClips`**: Virtual clip creation and cut point management
  - **`Clips.Export`**: Final encoding from gold master to physical clips (batch processing)
  - **`Clips.Edits`**: User-driven transformations (Split, Merge) - **now instant database operations on virtual clips**
  - **`Clips.Artifacts`**: Pipeline-driven processing (Keyframe) that create supplementary data
- **`Clips.Review`**: Human review workflow with **WebCodecs-based seeking** and instant virtual clip operations
- **`Clips.Embeddings`**: ML embedding generation and queries (operates on exported physical clips)

### Legacy Architecture (Transitional)

- **`Videos.Splice`**: Python scene detection creating physical clips via file encoding
- **`Clips.Artifacts.Sprite`**: Sprite sheet generation for traditional review UI
- **Traditional Review**: Sprite-based navigation with file-based merge/split operations

### Infrastructure

- **`Infrastructure`**: I/O adapters (S3, FFmpeg, Database) and shared worker behaviors with consistent interfaces and robust error handling
- **Python Tasks**: 
  - **`download.py`**: Quality-focused video download with conditional normalization for merge issue prevention
  - **`download_handler.py`**: yt-dlp integration with best-quality-first strategy and intelligent fallback
  - **`preprocess.py`**: FFmpeg gold master + proxy generation with progress reporting
  - **`detect_scenes.py`**: OpenCV scene detection returning cut points for virtual clips
  - **`export_clips.py`**: Batch encoding from gold master to delivery-optimized MP4s
  - **`s3_handler.py`**: Centralized S3 operations with storage class optimization

## Production Reliability Features

### Resumable Processing and Container Resilience
- **Automatic Resume**: All pipeline stages support resumable processing after container restarts
- **State-Based Recovery**: Workers detect and handle intermediate states (downloading, splicing, generating_sprite, etc.)
- **Temporary File Management**: Automatic cleanup of orphaned temporary files from previous runs on startup
- **Progress Preservation**: Partial work is preserved and continued rather than restarted

### Sprite Generation Reliability
- **Rust Integration**: Efficient sprite generation using `rambo` binary
- **Docker Support**: Multi-stage Dockerfile with Rust toolchain for rambo compilation
- **Error Handling**: Comprehensive error handling for sprite generation failures
- **State Management**: Proper state transitions with idempotent worker patterns

### S3 Operations Robustness
- **Flexible Response Handling**: S3 deletion operations handle both XML and JSON responses
- **Error Recovery**: Graceful handling of S3 API variations and network issues
- **Resource Cleanup**: Proper cleanup of temporary files and S3 objects
- **Idempotent Operations**: Safe retry mechanisms for failed S3 operations

### State Transition Management
- **Idempotent Workers**: All workers check current state before processing to prevent duplicate work
- **Concurrent Safety**: Prevents multiple workers from processing the same clip
- **Error Recovery**: Comprehensive error handling with detailed logging
- **Database Consistency**: Proper datetime handling and schema validation

### Database Schema Robustness
- **Timestamp Standardization**: Consistent datetime handling across all tables
- **Event Table Organization**: Semantic table naming for clarity
- **Index Optimization**: Database performance optimized with proper indexing
- **Data Integrity**: Enhanced validation and constraint handling

## Key Benefits

### Virtual Clip Architecture Benefits

1. **Zero Re-encoding During Review**: Virtual clips are database records only - instant merge/split operations with no file processing
2. **Lossless Quality Preservation**: Final clips encoded from uncompressed FFV1 gold master, not lossy proxy files
3. **Universal Workflow**: Single ingest path handles both web-scraped shows and user-uploaded clips seamlessly
4. **Instant Review Operations**: WebCodecs-based frame seeking with database-only merge/split transactions
5. **Efficient Storage**: Review proxies use all-I-frame encoding for perfect seeking without full source downloads

### Production Architecture Benefits

6. **Production Reliable**: Resumable processing handles container restarts gracefully with automatic recovery
7. **Clear Architecture**: Functional domain modeling with "I/O at the edges" and semantic organization
8. **Type-Safe**: Structured result types with compile-time validation and rich metadata
9. **Hybrid Efficient**: Elixir orchestration with Python for CV/ML/media processing - optimal performance
10. **Zero Boilerplate**: Centralized WorkerBehavior eliminates repetitive code while maintaining full functionality
11. **Declarative Pipeline**: Single source of truth for workflow orchestration with clear separation of concerns
12. **Idempotent Operations**: All workers implement robust idempotency patterns for safe retries
13. **Comprehensive Testing**: Pure functions enable thorough testing without I/O dependencies
14. **Semantic Organization**: Operations organized by business purpose for improved maintainability
15. **Scalable Design**: Robust orchestration patterns support production workloads with container resilience

---

## Implementation Status

### ✅ Completed (Virtual Clip Backend Pipeline)

- **Database Schema**: Added virtual clip support with `is_virtual`, `cut_points`, proxy architecture columns
- **PreprocessWorker**: Creates lossless gold master + all-I-frame proxy + keyframe offsets  
- **DetectScenesWorker**: Creates virtual clips (database records) from proxy file analysis
- **VirtualClips Module**: Cut point validation and virtual clip database operations
- **ExportWorker**: Batch export from gold master to final delivery MP4s
- **Python Tasks**: `preprocess.py`, updated `detect_scenes.py`, `export_clips.py`
- **Pipeline Integration**: Updated `PipelineConfig` with new virtual clip stages
- **Type Safety**: All Dialyzer warnings resolved, production-ready code quality
- **Enhanced Download Workflow**: Quality-first download strategy with conditional normalization
- **S3 Integration**: Centralized S3 operations with storage class optimization
- **Organizational Cleanup**: Flattened directory structure, removed legacy Events functionality

### 🚧 In Progress / Next Steps

- **WebCodecs Player**: JavaScript player using keyframe offsets for frame-perfect seeking
- **Review UI Updates**: LiveView integration with virtual clip operations  
- **Review Module**: Update `Clips.Review` for instant virtual merge/split operations
- **S3 Integration**: Connect Python tasks to real S3 download/upload operations
- **Legacy Migration**: Gradual transition from sprite-based to WebCodecs-based review

### 🎯 Future Enhancements

- **Performance Monitoring**: Track virtual vs physical operation performance metrics
- **Advanced Export Settings**: Quality profiles and codec configurations
- **Batch Review Tools**: Multi-clip approval and management workflows 