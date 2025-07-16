# Heaters Video Processing Pipeline

## Overview

Heaters processes videos through a multi-stage pipeline: ingestion → clips → human review → approval → embedding. The system emphasizes functional architecture with "I/O at the edges", direct action execution with buffer-time undo, and **hybrid processing** combining native Elixir (scene detection) with Python (ML/media processing) for optimal performance and reliability.

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

```
Source Video: new → downloading → downloaded → splicing → spliced
                      ↓              ↓           ↓
               download_failed  (resumable)  splicing_failed
                      ↑                          ↑
                      └──────────┬───────────────┘
                                 ↓
                          (resumable processing)

Clips: spliced → generating_sprite → pending_review → review_approved → keyframing → keyframed → embedding → embedded
          ↓              ↓                ↓                 ↓              ↓           ↓           ↓
    sprite_failed  (resumable)   review_skipped    review_archived   keyframe_failed  (resumable) embedding_failed
          ↑                           ↓                 ↓              ↑                              ↑
          └─────┬─────────────────────┼─────────────────┼──────────────┘                              │
                ↓                     ↓                 ↓                                              │
        (resumable processing)  (terminal state)   archive → cleanup                                   │
                                     ↑                                                                │
                                     │                                                                │
                              merge/split → new clips → spliced                                       │
                              (60s buffer)                ↓                                          │
                                     ↑                    └─────────────┬──────────────────────────────┘
                                     └──────────────────────────────────┘
                                                    (resumable processing)
```

## Key Design Decisions

### Semantic Operations Organization

The `Clips.Operations` context is organized by **operation type**, not file type:

- **`operations/edits/`**: User actions that create new clips and enter review workflow
  - `Merge`, `Split` operations (write to `clips` table)
- **`operations/artifacts/`**: Pipeline stages that generate supplementary data  
  - `Sprite`, `Keyframe`, `ClipArtifact` operations (write to `clip_artifacts` table)
- **`operations/archive/`**: Cleanup operations for archived clips
  - `Archive` worker (S3 deletion and database cleanup)

This reflects the fundamental difference between human review actions and automated processing stages.

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
- **Implementation**: `Videos.Operations.Splice` with Python task execution via PyRunner
- **Idempotency**: S3-based scene detection caching and clip existence checking prevents reprocessing

#### Native Elixir Keyframe Extraction
- **Technology**: Native Elixir FFmpeg implementation for high-performance keyframe extraction
- **Benefits**: Eliminates subprocess overhead and JSON parsing for better performance
- **Implementation**: `Clips.Operations.Artifacts.Keyframe` with direct FFmpeg calls via `Infrastructure.FFmpegAdapter`
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

### Resumable Processing Architecture

The system provides comprehensive resumable processing to handle container restarts and interruptions:

- **Container Restart Resilience**: If containers shut down mid-processing, work resumes automatically when restarted
- **No Manual Intervention**: Interrupted jobs are detected and resumed without operator action
- **State-Based Recovery**: Each worker can handle items in intermediate states (downloading, splicing, generating_sprite, etc.)
- **Temporary File Cleanup**: Orphaned temporary files from previous runs are cleaned up on application startup
- **Progress Preservation**: Partial work is not lost and doesn't need to be repeated

**Resumable States by Stage**:
- **Ingest**: `new`, `downloading`, `download_failed`
- **Splice**: `downloaded`, `splicing`, `splicing_failed`
- **Sprite**: `spliced`, `generating_sprite`, `sprite_failed`
- **Keyframe**: `review_approved`, `keyframing`, `keyframe_failed`
- **Embedding**: `keyframed`, `embedding`, `embedding_failed`
- **Archive**: `review_archived`

This architecture ensures maximum reliability in production environments where container restarts are common.

## Workflow Examples

### Video Ingestion
1. `Videos.submit/1` creates source video in `new` state
2. `Videos.Operations.Ingest.Worker` downloads/processes → `downloaded` state  
3. `Videos.Operations.Splice.Worker` runs **Python scene detection** → clips in `spliced` state

### Review Workflow
1. `Clips.Operations.Artifacts.Sprite.Worker` generates sprites using rambo → clips in `pending_review` state
2. Human reviews and takes actions:
   - **approve** → `review_approved` (continues to keyframes)
   - **skip** → `review_skipped` (terminal, preserves sprite)
   - **archive** → `review_archived` (cleanup via archive worker)
   - **group** → both clips → `review_approved` with `grouped_with_clip_id` metadata
   - **merge/split** → 60-second buffer → worker creates new clips → `spliced` state
3. Actions execute directly with Oban reliability, new clips flow back through pipeline

### Post-Approval Processing
1. `Clips.Operations.Artifacts.Keyframe.Worker` extracts keyframes → `keyframed` state
2. `Clips.Embeddings.Worker` generates ML embeddings → `embedded` state (final)

### Archive Workflow
1. `Clips.Operations.Archive.Worker` safely deletes S3 objects and database records
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
- **Action Stages**: `call` function executes direct operations (EventProcessor)
- **Declarative Flow**: All state transitions handled by pipeline, not workers

**`Infrastructure.Orchestration.PipelineConfig`** provides complete workflow as data:
1. `new videos → download` (IngestWorker)
2. `downloaded videos → splice` (SpliceWorker) 
3. `spliced clips → sprites` (SpriteWorker) ← **Handles ALL spliced clips (original, merged, and split)**
4. `approved clips → keyframes` (KeyframeWorker)
5. `keyframed clips → embeddings` (EmbeddingWorker)
6. `archived clips → archive` (ArchiveWorker)

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

- **`Videos`**: Source video lifecycle from submission through clips creation
  - **`Videos.Operations.Ingest`**: Video download and processing workflow
  - **`Videos.Operations.Splice`**: Python scene detection using OpenCV via PyRunner port communication
- **`Clips.Operations`**: Clip transformations and state management (semantic Edits/Artifacts organization)
  - **`Clips.Operations.Edits`**: User-driven transformations (Split, Merge) that create new clips
    - **Split Operations**: Uses hybrid approach with absolute timestamp calculations in domain logic and clip-relative extraction for I/O efficiency
  - **`Clips.Operations.Artifacts`**: Pipeline-driven processing (Sprite, Keyframe) that create supplementary data
- **`Clips.Review`**: Human review workflow and action coordination  
- **`Clips.Embeddings`**: ML embedding generation and queries
- **`Infrastructure`**: I/O adapters (S3, FFmpeg, Database) and shared worker behaviors with consistent interfaces and robust error handling

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

1. **Production Reliable**: Resumable processing handles container restarts gracefully with automatic recovery
2. **Clear Architecture**: Functional domain modeling with "I/O at the edges" and semantic organization
3. **Type-Safe**: Structured result types with compile-time validation and rich metadata
4. **Hybrid Efficient**: Native Elixir for video operations, Python for ML/scene detection - optimal performance
5. **Zero Boilerplate**: Centralized WorkerBehavior eliminates repetitive code while maintaining full functionality
6. **Declarative Pipeline**: Single source of truth for workflow orchestration with clear separation of concerns
7. **Idempotent Operations**: All workers implement robust idempotency patterns for safe retries
8. **Comprehensive Testing**: Pure functions enable thorough testing without I/O dependencies
9. **Semantic Organization**: Operations organized by business purpose for improved maintainability
10. **Scalable Design**: Robust orchestration patterns support production workloads with container resilience 