# Heaters Video Processing Workflow

## Overview

Heaters is a video processing pipeline that ingests videos, splits them into clips, prepares them for human review, and processes approved clips for final use. The system follows a clean functional architecture with "I/O at the edges", "dumb" Python tasks focused on media processing, and "smart" Elixir contexts managing business logic and state transitions.

## Architecture Principles

- **Functional Domain Modeling**: "I/O at the edges" architecture with pure business logic separated from I/O operations
- **Pure Domain Functions**: Business logic implemented as pure functions with predictable inputs/outputs
- **Infrastructure Adapters**: Clean I/O boundaries with consistent interfaces for database, S3, and FFmpeg operations
- **Python Tasks**: Pure media processing functions (video/image/ML operations)
- **Elixir Contexts**: Business logic, state management, and workflow orchestration
- **Oban Workers**: Job orchestration and error handling with standardized patterns
- **Event Sourcing**: Human review actions tracked via `clip_events` table
- **Structured Results**: All transform operations return type-safe Result structs
- **Generic Workers**: Standardized worker behavior eliminates boilerplate and ensures consistency

## State Flow Overview

```
Source Video: new → downloading → downloaded → splicing → spliced
                                                    ↓
Clips: spliced → generating_sprite → pending_review → review_approved → keyframing → keyframed → embedding → embedded
                                          ↓
                                   review_archived (terminal)
                                          ↓
                                   merge/split → new clips → generating_sprite
```

## Detailed Workflow

### 1. Video Ingestion (`Videos.Ingest` Context)

**States**: `new` → `downloading` → `downloaded` → `splicing` → `spliced`

**Workers**: 
- `Videos.IngestWorker`: Downloads and processes source videos
- `Videos.SpliceWorker`: Splits videos into clips to complete ingestion

**Python Tasks**:
- `ingest.py`: Download, re-encode, upload to S3
- `splice.py`: Split video into clips using scene detection

**Process**:
1. Source video created in `new` state
2. `Videos.IngestWorker` transitions to `downloading` → calls `ingest.py` → transitions to `downloaded`
3. `Videos.SpliceWorker` transitions to `splicing` → calls `splice.py` → transitions to `spliced`
4. Clips created in `spliced` state, `Clips.SpriteWorker` jobs enqueued

### 2. Clip Review Preparation (`Clips.Operations` Context)

**States**: `spliced` → `generating_sprite` → `pending_review`

**Workers**:
- `Clips.SpriteWorker`: Generates sprite sheets for human review

**Operations Modules**:
- `Heaters.Clips.Operations.Sprite`: Generate sprite sheets using FFmpeg (pure Elixir implementation)
- Returns structured `SpriteResult` with status, artifacts, metadata, and performance timing

**Process**:
1. Clips created in `spliced` state after video splicing
2. `Clips.SpriteWorker` uses `Operations` context to transition to `generating_sprite` → calls `Clips.Operations.Sprite.run_sprite/2` → transitions to `pending_review`
3. `SpriteResult` provides structured data including sprite artifacts and generation metadata
4. Clips now ready for human review with sprite sheets

### 3. Human Review Process (`Clips.Review` Context)

**States**: `pending_review` → `review_approved` | `review_archived`

**Actions**: Approve, Archive, Merge, Split, Group, Skip, Undo

**Event Sourcing**: All actions logged in `clip_events` table

**Process**:
1. Human reviewers examine clips in `pending_review` state
2. Review actions create events and update clip states
3. **Merge/Split operations**:
   - Create new clips in `spliced` state
   - Automatically enqueue `Clips.SpriteWorker` for new clips
   - New clips flow back through sprite generation → review

### 4. Post-Approval Processing (`Clips.Operations` + `Clips.Embedding` Contexts)

**States**: `review_approved` → `keyframing` → `keyframed` → `embedding` → `embedded`

**Workers**:
- `Clips.KeyframeWorker`: Extracts keyframes for embedding generation
- `Clips.EmbeddingWorker`: Generates ML embeddings from keyframes

**Operations Modules**:
- `Heaters.Clips.Operations.Keyframe`: Keyframe extraction coordination (Python OpenCV integration)
- Returns structured `KeyframeResult` with status, artifacts, keyframe count, and strategy metadata
- `Heaters.Clips.Embedding`: Embedding generation coordination
- Returns structured `EmbedResult` with status, embedding ID, model info, and dimensions

**Python Tasks**:
- `keyframe.py`: Extract keyframes using OpenCV
- `embed.py`: Generate embeddings using CLIP/DINOv2 models

**Process**:
1. Approved clips transition from `review_approved` to `keyframing`
2. `Clips.KeyframeWorker` calls `Operations.Keyframe.run_keyframe_extraction/2` → returns `KeyframeResult` → transitions to `keyframed`
3. `Clips.EmbeddingWorker` calls `Embedding.process_embedding_success/2` → returns `EmbedResult` → transitions to `embedded`
4. Structured results provide rich metadata including keyframe counts, embedding dimensions, and model information
5. Clips now ready for final use with embeddings

## Functional Architecture

### Domain-Driven Design with "I/O at the Edges"

The system implements functional domain modeling principles inspired by "Domain Modeling Made Functional":

**Pure Domain Layer**:
- **Business Logic**: Pure functions with no I/O dependencies in `operations/*/` subdirectories
- **Domain Types**: Shared types and validation logic in `operations/shared/`
- **Calculations**: Mathematical operations (sprite grids, split boundaries, video metadata)
- **Validation**: Business rule validation with structured error types
- **File Naming**: Consistent naming conventions across operations

**Infrastructure Layer**:
- **I/O Adapters**: Clean interfaces for database, S3, FFmpeg, and Python operations
- **Infrastructure Utilities**: Temp file management, FFmpeg runners, result builders
- **Consistent Interfaces**: All adapters follow the same error handling and return patterns

**I/O Orchestration Layer**:
- **Operations Modules**: Coordinate between pure domain logic and infrastructure adapters
- **State Management**: Handle clip state transitions with proper error handling
- **Result Assembly**: Combine domain calculations with I/O operation results

### Benefits of Functional Architecture

1. **Testability**: Pure domain functions can be tested without I/O mocking
2. **Reliability**: Predictable functions with clear inputs/outputs reduce bugs
3. **Maintainability**: Clear separation of concerns makes code easier to understand
4. **Performance**: Property-based testing validates business logic invariants
5. **Composability**: Pure functions can be easily combined and reused

## Context Organization

### `Videos.Ingest` (`lib/heaters/videos/ingest.ex`)
- **Purpose**: Manage complete video ingestion workflow from download through clip creation
- **States**: `new`, `downloading`, `downloaded`, `splicing`, `spliced`
- **Key Functions**: `start_downloading/1`, `complete_downloading/2`, `start_splicing/1`, `complete_splicing/1`, `create_clips_from_splice/2`, `validate_clips_data/1`
- **Workers**: `Videos.IngestWorker`, `Videos.SpliceWorker`

### `Videos.Intake` (`lib/heaters/videos/intake.ex`)
- **Purpose**: Simple interface for submitting new source videos
- **Key Functions**: `submit/1` - Creates new source videos in "new" state

### `Events` (`lib/heaters/events/`)
- **Purpose**: Event sourcing infrastructure for review actions using CQRS pattern
- **Key Modules**:
  - `Events.Events`: Write-side event creation API
  - `Events.EventProcessor`: Read-side event processing and job orchestration
- **Key Functions**: `log_review_action/4`, `log_merge_action/3`, `log_split_action/3`, `commit_pending_actions/0`
- **Benefits**: Audit trail, reliable job queuing, separation of write/read operations

### `Clips.Review` (`lib/heaters/clips/review.ex`)
- **Purpose**: Human review workflow coordination and review actions
- **States**: `pending_review`, `review_approved`, `review_archived`
- **Key Functions**: Review action orchestration, fetching clips for review, review-specific queries
- **Related Contexts**: Uses `Events` for action logging, coordinates with `Operations` for merge/split operations

### `Clips.Operations` (`lib/heaters/clips/operations.ex`)
- **Purpose**: I/O orchestration layer for all clip transformation operations and state management
- **States**: `spliced`, `generating_sprite`, `pending_review`, `keyframing`, `keyframed` (various transformation states)
- **Key Functions**: Sprite state management, error handling, artifact management, S3 path generation
- **Architecture**: Functional "I/O at the edges" design with pure domain logic separated from I/O operations
- **Specialized Modules**:
  - `Clips.Operations.Sprite`: Sprite sheet generation (native Elixir with FFmpeg) → `SpriteResult`
  - `Clips.Operations.Merge`: Clip merging operations (native Elixir with FFmpeg) → `MergeResult`
  - `Clips.Operations.Split`: Clip splitting operations (native Elixir with FFmpeg) → `SplitResult`
  - `Clips.Operations.Keyframe`: Keyframe extraction (Python OpenCV integration) → `KeyframeResult`
- **Domain Logic**: Pure business functions in `operations/sprite/`, `operations/keyframe/`, `operations/split/`, `operations/merge/`
- **Shared Infrastructure**: Common utilities and domain logic in `operations/shared/`

### `Clips.Embedding` (`lib/heaters/clips/embedding.ex`)
- **Purpose**: ML embedding generation and storage
- **States**: `keyframed`, `embedding`, `embedded`
- **Key Functions**: `start_embedding/1`, `process_embedding_success/2`, embedding queries
- **Architecture**: Returns structured `EmbedResult` with embedding metadata, model information, and dimensions

## Worker Organization

Following Elixir/Phoenix best practices, all workers are organized in `lib/heaters/workers/` by domain and use the standardized `GenericWorker` behavior for consistent error handling, logging, and job orchestration:

### Videos Workers (`lib/heaters/workers/videos/`)
- `IngestWorker` - Downloads and processes source videos
- `SpliceWorker` - Splits videos into clips based on scene detection

### Clips Workers (`lib/heaters/workers/clips/`)
- `SpriteWorker` - Generates sprite sheets for review preparation (native Elixir with FFmpeg) → handles `SpriteResult`
- `MergeWorker` - Merges two clips together (review action, native Elixir with FFmpeg) → handles `MergeResult`
- `SplitWorker` - Splits a clip at a specific frame (review action, native Elixir with FFmpeg) → handles `SplitResult`
- `ArchiveWorker` - Cleans up archived clips from S3 and database
- `KeyframeWorker` - Extracts keyframes for embedding generation (Python OpenCV) → handles `KeyframeResult`
- `EmbeddingWorker` - Generates ML embeddings from clip content (Python ML models) → handles `EmbedResult`

### Orchestration Workers (`lib/heaters/workers/`)
- `Dispatcher` - Data-driven batch job orchestration and workflow management (reduced from 98 to 42 lines)

### Generic Worker Behavior (`lib/heaters/workers/generic_worker.ex`)
- **Purpose**: Standardized worker behavior eliminating boilerplate across all workers
- **Features**: Automatic error handling, structured logging, performance timing, next-stage job enqueuing
- **Benefits**: Consistent retry logic, graceful error recovery, centralized telemetry and observability
- **Interface**: Workers implement `handle/1` for business logic and optional `enqueue_next/1` for follow-up jobs

## Orchestration

### Dispatcher (`lib/heaters/workers/dispatcher.ex`)

**Data-driven architecture** - Runs periodically using configurable step definitions to find work and enqueue jobs:

1. **Step 1**: Find `new` videos → enqueue `Videos.IngestWorker`
2. **Step 2**: Find `spliced` clips → enqueue `Clips.SpriteWorker` 
3. **Step 3**: Process pending review actions via `EventProcessor.commit_pending_actions()` (merge/split)
4. **Step 4**: Find `review_approved` clips → enqueue `Clips.KeyframeWorker`
5. **Step 5**: Find `keyframed` clips → enqueue `Clips.EmbeddingWorker`
6. **Step 6**: Find `review_archived` clips → enqueue `Clips.ArchiveWorker`

**Improvements**:
- Reduced from 98 to 42 lines through data-driven step configuration
- Standardized step execution pattern eliminates code duplication
- Easy to add new steps or modify existing workflow logic
- Centralized error handling and logging for all dispatch operations

## Python Task Interface

All Python tasks follow a consistent pattern:

```python
def run_task_name(explicit_params, **kwargs) -> dict:
    """
    Pure media processing function.
    
    Args:
        explicit_params: All required data passed from Elixir
        **kwargs: Optional parameters
    
    Returns:
        dict: Structured result data for Elixir to process
    """
```

**Key Characteristics**:
- No database connections
- Receive explicit S3 paths and parameters
- Return structured JSON data
- Focus solely on media processing
- Include progress reporting and error handling
- Automatic S3 cleanup of source files after successful processing (merge/split operations)

## Python Task Organization

### Core Tasks (`py/tasks/`)
- `ingest.py`: Video download and re-encoding
- `splice.py`: Video scene detection and splitting
- `keyframe.py`: Keyframe extraction using OpenCV
- `embed.py`: ML embedding generation using CLIP/DINOv2

### Legacy Tasks (`py_tasks/`)
- (sprite.py was migrated to pure Elixir implementation)
- (merge.py and split.py were never implemented - operations use native Elixir with FFmpeg)

### Runner Infrastructure
- `py/runner.py`: Main entry point for all Python task execution
- `py/utils/`: Shared utilities for S3 operations and common functions

## State Transition Rules

### Source Video States
- `new` → `downloading` (via `IngestWorker`)
- `downloading` → `downloaded` (via `ingest.py` success)
- `downloaded` → `splicing` (via `SpliceWorker`)
- `splicing` → `spliced` (via `splice.py` success)

### Clip States
- `spliced` → `generating_sprite` (via `SpriteWorker`)
- `generating_sprite` → `pending_review` (via `Sprite.run_sprite/1` success)
- `pending_review` → `review_approved` (via human action)
- `pending_review` → `review_archived` (via human action)
- `review_approved` → `keyframing` (via `KeyframeWorker`)
- `keyframing` → `keyframed` (via `keyframe.py` success)
- `keyframed` → `embedding` (via `EmbeddingWorker`)
- `embedding` → `embedded` (via `embed.py` success)

### Error States
- `ingestion_failed`, `splicing_failed` (source videos)
- `sprite_failed`, `keyframing_failed`, `embedding_failed` (clips)

## Error Handling

- **Retry Logic**: Failed jobs can be retried with exponential backoff
- **State Tracking**: Error states allow for targeted retry strategies
- **Comprehensive Logging**: All state transitions and errors logged
- **Graceful Degradation**: Failed clips don't block other clips in the pipeline

## S3 Operations

### Elixir S3 Context (`lib/heaters/infrastructure/s3.ex`)
- **Purpose**: Unified S3 operations interface, particularly for cleanup operations
- **Used by**: `ArchiveWorker` for deleting archived clips and artifacts
- **Benefits**: Environment-aware (dev/prod buckets), comprehensive error handling, batched operations

### Python S3 Utils (`py/utils/s3_utils.py`)
- **Purpose**: Common S3 deletion utilities for media processing tasks
- **Used by**: `merge.py` and `split.py` for cleaning up source files after successful processing
- **Benefits**: Reusable code, consistent error handling, atomic with media operations
- **Features**: Batched deletion (respects S3 1000 object limit), comprehensive error reporting

### S3 Deletion Strategy
- **Archive operations**: Pure cleanup in Elixir (review_archived clips)
- **Merge/Split operations**: Cleanup in Python as part of atomic media processing
- **Environment handling**: Automatic dev/prod bucket selection via configuration

## Structured Result Types

All transform operations now return standardized Result structs for type safety and enhanced observability:

### Transform Result Structs
- **`SplitResult`**: Status, original_clip_id, new_clip_ids, created_clips, cleanup metadata
- **`SpriteResult`**: Status, clip_id, artifacts, metadata, processing duration  
- **`KeyframeResult`**: Status, clip_id, artifacts, keyframe_count, strategy, processing duration
- **`MergeResult`**: Status, merged_clip_id, source_clip_ids, cleanup metadata, processing duration
- **`EmbedResult`**: Status, clip_id, embedding_id, model_name, embedding_dim, processing duration

### Benefits of Structured Results
- **Type Safety**: Compile-time validation with `@enforce_keys` for required fields
- **Enhanced Observability**: Rich metadata including performance timing and operation-specific details
- **Consistent Interface**: All transforms follow the same return pattern
- **Better Error Handling**: Structured status reporting with detailed error context
- **Performance Monitoring**: Built-in timing and metadata for operations analysis
- **Direct Access**: Workers can access fields directly without defensive `Map.get` operations

## Key Benefits

1. **Clear Separation**: Media processing (Python) vs business logic (Elixir) vs I/O operations (Infrastructure)
2. **Maintainable**: Each context has focused responsibilities with standardized patterns and functional architecture
3. **Scalable**: Independent job processing with proper error handling and centralized worker behavior
4. **Flexible**: Data-driven dispatcher makes workflow modifications easy
5. **Reliable**: Comprehensive state management and error recovery with structured Result types
6. **Testable**: Pure functions with predictable inputs/outputs and type-safe return structures
7. **Environment-Aware**: Automatic dev/prod S3 bucket handling
8. **Type-Safe**: All transform operations return structured Result types with compile-time validation
9. **Observable**: Enhanced logging with domain-specific metadata (keyframe counts, embedding dimensions, performance timing)
10. **Consistent**: GenericWorker behavior eliminates boilerplate and ensures uniform error handling across all workers
11. **Performance**: Optimized pattern matching without defensive programming (direct struct field access vs Map.get)
12. **Developer Experience**: Reduced code complexity with improved maintainability through functional architecture
13. **Pure Domain Logic**: Business rules can be tested without I/O dependencies or mocking
14. **Property-Based Testing**: Pure functions enable comprehensive property-based testing for business invariants
15. **Clean Architecture**: "I/O at the edges" principle ensures clear boundaries between pure logic and side effects 