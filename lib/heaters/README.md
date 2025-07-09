# Heaters Video Processing Pipeline

## Overview

Heaters processes videos through a multi-stage pipeline: ingestion → clips → human review → approval → embedding. The system emphasizes functional architecture with "I/O at the edges", event sourcing for human actions, and **hybrid processing** combining native Elixir (scene detection) with Python (ML/media processing) for optimal performance and reliability.

### Technology Stack
- **Backend**: Elixir/Phoenix with LiveView
- **Database**: PostgreSQL with pgvector extension
- **Scene Detection**: Native Elixir using Evision (OpenCV bindings)
- **ML Processing**: Python with PyTorch, Transformers
- **Media Processing**: Python with yt-dlp, FFmpeg, Rust (rambo for sprite generation)
- **Storage**: AWS S3 with idempotent operations and robust error handling
- **Background Jobs**: Oban with PostgreSQL and idempotent worker patterns

## Architecture Principles

- **Functional Domain Modeling**: "I/O at the edges" with pure business logic separated from I/O operations
- **Semantic Organization**: Clear distinction between user **Edits** (review actions) and automated **Artifacts** (pipeline stages)
- **Event Sourcing**: Human review actions tracked via `review_events` table for audit and reliability
- **Structured Results**: Type-safe Result structs with rich metadata and performance timing
- **Centralized Worker Behavior**: Standardized Oban worker patterns with shared lifecycle management, error handling, and idempotent state validation
- **Hybrid Processing**: Native Elixir for performance-critical operations (scene detection), Python for ML/media processing
- **Robust Error Handling**: Graceful degradation with comprehensive logging and state recovery

## State Flow

```
Source Video: new → downloading → downloaded → splicing → spliced
                                                    ↓
Clips: spliced → generating_sprite → pending_review → review_approved → keyframing → keyframed → embedding → embedded
                                          ↓
                                   review_archived (terminal)
                                          ↓
                                   merge/split → new clips → generating_sprite
```

## Key Design Decisions

### Semantic Operations Organization

The `Clips.Operations` context is organized by **operation type**, not file type:

- **`operations/edits/`**: User actions that create new clips and enter review workflow
  - `Merge`, `Split` operations (write to `clips` table)
- **`operations/artifacts/`**: Pipeline stages that generate supplementary data  
  - `Sprite`, `Keyframe`, `ClipArtifact` operations (write to `clip_artifacts` table)

This reflects the fundamental difference between human review actions and automated processing stages.

### Event Sourcing for Review Actions

Human review actions use CQRS pattern:
- **Write-side**: `Events.Events` logs all actions to `review_events` table
- **Read-side**: `Events.EventProcessor` processes events and orchestrates follow-up jobs
- **Benefits**: Audit trail, reliable job queuing, ability to replay/undo actions

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

The system uses a **hybrid approach** combining native Elixir and Python processing:

#### Native Elixir Scene Detection
- **Technology**: Evision (OpenCV-Elixir bindings) for high-performance scene detection
- **Benefits**: Eliminates subprocess communication and JSON parsing brittleness
- **Implementation**: `Videos.Operations.Splice` with streaming frame-by-frame processing
- **Idempotency**: S3-based clip existence checking prevents reprocessing

#### Python ML/Media Processing
- **Technology**: Python for ML embedding generation and media processing
- **Benefits**: Leverages mature ML ecosystems and specialized media libraries
- **Interface**: Pure functions with structured JSON responses, no database access
- **Rust Integration**: Uses `rambo` binary for efficient sprite generation

```python
# Python tasks remain pure media processing functions
def run_task_name(explicit_params, **kwargs) -> dict:
    # Pure media processing - no DB connections
    # Return structured JSON for Elixir processing
```

### Structured Result Types

All operations return type-safe structs with `@enforce_keys`:

```elixir
%SpriteResult{status: "success", clip_id: 123, artifacts: [...], duration_ms: 1500}
%KeyframeResult{status: "success", keyframe_count: 8, strategy: "uniform"}
%MergeResult{status: "success", merged_clip_id: 456, cleanup: %{...}}
%SpliceResult{status: "success", clips_data: [...], total_scenes_detected: 25}
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

## Workflow Examples

### Video Ingestion
1. `Videos.submit/1` creates source video in `new` state
2. `Videos.Operations.Ingest.Worker` downloads/processes → `downloaded` state  
3. `Videos.Operations.Splice.Worker` runs **native Elixir scene detection** → clips in `spliced` state

### Review Workflow
1. `Clips.Operations.Artifacts.Sprite.Worker` generates sprites using rambo → clips in `pending_review` state
2. Human reviews and takes actions (approve/archive/merge/split)
3. Actions logged via event sourcing, new clips automatically flow back through pipeline

### Post-Approval Processing
1. `Clips.Operations.Artifacts.Keyframe.Worker` extracts keyframes → `keyframed` state
2. `Clips.Embeddings.Worker` generates ML embeddings → `embedded` state (final)

### Archive Workflow
1. `Clips.Review.ArchiveWorker` safely deletes S3 objects and database records
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
3. `spliced clips → sprites` (SpriteWorker) ← **Handles ALL spliced clips**
4. `review actions` (EventProcessor.commit_pending_actions)
5. `approved clips → keyframes` (KeyframeWorker)
6. `keyframed clips → embeddings` (EmbeddingWorker)
7. `archived clips → archive` (ArchiveWorker)

### Key Architectural Decision: Single Source of Truth

**Before**: Mixed imperative/declarative approach with workers directly enqueueing other workers
- SpliceWorker → SpriteWorker (imperative)
- MergeWorker → SpriteWorker (imperative) 
- SplitWorker → SpriteWorker (imperative)

**After**: Fully declarative pipeline with single source of truth
- ALL workers focus purely on domain logic and state transitions
- Pipeline dispatcher handles ALL enqueueing based on database state
- "spliced clips → sprites" stage catches clips from splice, merge, AND split operations
- Zero direct worker-to-worker communication

**Benefits**: Single source of truth, easier testing, clearer workflow visibility, separation of concerns between business logic and orchestration.

## Context Responsibilities

- **`Videos`**: Source video lifecycle from submission through clips creation
  - **`Videos.Operations.Ingest`**: Video download and processing workflow
  - **`Videos.Operations.Splice`**: Native Elixir scene detection using Evision (OpenCV bindings)
- **`Clips.Operations`**: Clip transformations and state management (semantic Edits/Artifacts organization)
  - **`Clips.Operations.Edits`**: User-driven transformations (Split, Merge) that create new clips
  - **`Clips.Operations.Artifacts`**: Pipeline-driven processing (Sprite, Keyframe) that create supplementary data
- **`Clips.Review`**: Human review workflow and action coordination  
- **`Clips.Embeddings`**: ML embedding generation and queries
- **`Events`**: Event sourcing infrastructure for review actions
- **`Infrastructure`**: I/O adapters (S3, FFmpeg, Database) and shared worker behaviors with consistent interfaces and robust error handling

## Recent Reliability Improvements

### Sprite Generation Reliability
- **Rust Integration**: Added `rambo` binary for efficient sprite generation
- **Docker Support**: Multi-stage Dockerfile with Rust toolchain for rambo compilation
- **Error Handling**: Comprehensive error handling for sprite generation failures
- **State Management**: Proper state transitions with idempotent worker patterns

### S3 Operations Robustness
- **Flexible Response Handling**: S3 deletion operations handle both XML and JSON responses
- **Error Recovery**: Graceful handling of S3 API variations and network issues
- **Resource Cleanup**: Proper cleanup of temporary files and S3 objects
- **Idempotent Operations**: Safe retry mechanisms for failed S3 operations

### State Transition Management
- **Idempotent Workers**: All workers check current state before processing
- **Concurrent Safety**: Prevents multiple workers from processing the same clip
- **Error Recovery**: Comprehensive error handling with detailed logging
- **Database Consistency**: Proper datetime handling and schema validation

### Database Schema Improvements
- **Timestamp Standardization**: Consistent datetime handling across all tables
- **Event Table Renaming**: `clip_events` → `review_events` for semantic clarity
- **Index Optimization**: Improved database performance with proper indexing
- **Data Integrity**: Enhanced validation and constraint handling

### Worker Organization and Consolidation ✅
- **Semantic Organization**: Workers moved to business contexts for improved cohesion
  - Video workers: `videos/operations/{ingest,splice}/worker.ex`
  - Clip edit workers: `clips/operations/edits/{split,merge}/worker.ex`
  - Clip artifact workers: `clips/operations/artifacts/{sprite,keyframe}/worker.ex`
  - Clip review workers: `clips/review/archive_worker.ex`
  - Embedding workers: `clips/embeddings/worker.ex`
  - Infrastructure workers: `infrastructure/orchestration/dispatcher.ex`
  - Infrastructure: `infrastructure/orchestration/{pipeline_config,worker_behavior}.ex`
- **Shared Worker Behavior**: `Infrastructure.Orchestration.WorkerBehavior` eliminates 450+ lines of boilerplate per worker across all 9 workers
  - Standardized performance monitoring and logging with automatic timing
  - Consistent error handling with detailed stack traces and exception recovery
  - Common idempotency patterns and helper functions (`check_complete_states`, `check_artifact_exists`)
  - Centralized job lifecycle management with robust error handling
  - Unified logging patterns with module-specific prefixes and structured output
- **Fully Declarative Pipeline**: Workers focus purely on domain logic with zero direct enqueueing
  - Pipeline dispatcher handles ALL job orchestration based on database state
  - Clean separation between business logic (workers) and orchestration (pipeline)
  - Single source of truth for workflow transitions eliminates imperative worker-to-worker communication
- **Improved Maintainability**: Workers now focus purely on business logic rather than infrastructure concerns
- **Type Safety**: Preserved all Dialyzer suppressions and maintained compile-time validation
- **Zero Downtime**: Refactoring maintained 100% backward compatibility with existing job queues

## Key Benefits

1. **Clear Separation**: Media processing vs business logic vs I/O operations
2. **Maintainable**: Functional architecture with pure domain logic
3. **Reliable**: Event sourcing, structured error handling, and robust state management
4. **Type-Safe**: Structured results with compile-time validation  
5. **Testable**: Pure functions without I/O dependencies
6. **Semantic**: Operations organized by business purpose, not implementation details
7. **Performance**: Native Elixir scene detection eliminates subprocess overhead and JSON parsing brittleness
8. **Hybrid Efficiency**: Best of both worlds - Elixir for performance-critical operations, Python for ML/media processing
9. **Production Ready**: Comprehensive error handling, logging, and recovery mechanisms
10. **Scalable**: Idempotent workers and robust orchestration patterns 
11. **Well-Organized**: Semantic worker organization by business context improves code discoverability and maintenance
12. **DRY Architecture**: Centralized WorkerBehavior eliminates 450+ lines of boilerplate across 9 workers while maintaining full functionality
13. **Declarative Orchestration**: Fully declarative pipeline provides single source of truth with clear separation between business logic and workflow orchestration 