# Heaters Video Processing Workflow

## Overview

Heaters is a video processing pipeline that ingests videos, splits them into clips, prepares them for human review, and processes approved clips for final use. The system follows a clean architecture with "dumb" Python tasks focused on media processing and "smart" Elixir contexts managing business logic and state transitions.

## Architecture Principles

- **Python Tasks**: Pure media processing functions (video/image/ML operations)
- **Elixir Contexts**: Business logic, state management, and workflow orchestration
- **Oban Workers**: Job orchestration and error handling
- **Event Sourcing**: Human review actions tracked via `clip_events` table

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

### 1. Video Ingestion (`Video.Ingest` Context)

**States**: `new` → `downloading` → `downloaded` → `splicing` → `spliced`

**Workers**: 
- `IngestWorker`: Downloads and processes source videos
- `SpliceWorker`: Splits videos into clips to complete ingestion

**Python Tasks**:
- `ingest.py`: Download, re-encode, upload to S3
- `splice.py`: Split video into clips using scene detection

**Process**:
1. Source video created in `new` state
2. `IngestWorker` transitions to `downloading` → calls `ingest.py` → transitions to `downloaded`
3. `SpliceWorker` transitions to `splicing` → calls `splice.py` → transitions to `spliced`
4. Clips created in `spliced` state, `SpriteWorker` jobs enqueued

### 2. Clip Review Preparation (`Clip.Review` Context)

**States**: `spliced` → `generating_sprite` → `pending_review`

**Workers**:
- `SpriteWorker`: Generates sprite sheets for human review

**Elixir Modules**:
- `Heaters.Clip.Transform.Sprite`: Generate sprite sheets using FFmpex (pure Elixir implementation)

**Process**:
1. Clips created in `spliced` state after video splicing
2. `SpriteWorker` transitions to `generating_sprite` → calls `Transform.Sprite.run_sprite/1` → transitions to `pending_review`
3. Clips now ready for human review with sprite sheets

### 3. Human Review Process (`Clip.Review` Context)

**States**: `pending_review` → `review_approved` | `review_archived`

**Actions**: Approve, Archive, Merge, Split, Group, Skip, Undo

**Event Sourcing**: All actions logged in `clip_events` table

**Process**:
1. Human reviewers examine clips in `pending_review` state
2. Review actions create events and update clip states
3. **Merge/Split operations**:
   - Create new clips in `spliced` state
   - Automatically enqueue `SpriteWorker` for new clips
   - New clips flow back through sprite generation → review

### 4. Post-Approval Processing (`Clip.Transform` + `Clip.Embed` Contexts)

**States**: `review_approved` → `keyframing` → `keyframed` → `embedding` → `embedded`

**Workers**:
- `KeyframeWorker`: Extracts keyframes for embedding generation
- `EmbeddingWorker`: Generates ML embeddings from keyframes

**Python Tasks**:
- `keyframe.py`: Extract keyframes using OpenCV
- `embed.py`: Generate embeddings using CLIP/DINOv2 models

**Process**:
1. Approved clips transition from `review_approved` to `keyframing`
2. `KeyframeWorker` calls `keyframe.py` → transitions to `keyframed`
3. `EmbeddingWorker` calls `embed.py` → transitions to `embedded`
4. Clips now ready for final use with embeddings

## Context Organization

### `Video.Ingest` (`lib/heaters/video/ingest.ex`)
- **Purpose**: Manage complete video ingestion workflow from download through clip creation
- **States**: `new`, `downloading`, `downloaded`, `splicing`, `spliced`
- **Key Functions**: `start_downloading/1`, `complete_downloading/2`, `start_splicing/1`, `complete_splicing/1`, `create_clips_from_splice/2`, `validate_clips_data/1`
- **Workers**: `IngestWorker`, `SpliceWorker`

### `Video.Intake` (`lib/heaters/video/intake.ex`)
- **Purpose**: Simple interface for submitting new source videos
- **Key Functions**: `submit/1` - Creates new source videos in "new" state

### `Events` (`lib/heaters/events/`)
- **Purpose**: Event sourcing infrastructure for review actions using CQRS pattern
- **Key Modules**:
  - `Events.Events`: Write-side event creation API
  - `Events.EventProcessor`: Read-side event processing and job orchestration
- **Key Functions**: `log_review_action/4`, `log_merge_action/3`, `log_split_action/3`, `commit_pending_actions/0`
- **Benefits**: Audit trail, reliable job queuing, separation of write/read operations

### `Clip.Review` (`lib/heaters/clip/review.ex`)
- **Purpose**: Human review workflow coordination and review actions
- **States**: `pending_review`, `review_approved`, `review_archived`
- **Key Functions**: Review action orchestration, fetching clips for review
- **Related Contexts**: Uses `Events` for action logging, coordinates with `Transform` for sprite/merge/split operations

### `Clip.Transform` (`lib/heaters/clip/transform.ex`)
- **Purpose**: Coordination layer for all clip transformation operations
- **States**: `spliced`, `generating_sprite`, `pending_review`, `keyframing`, `keyframed` (various transformation states)
- **Key Functions**: Shared utilities for error handling, artifact management, S3 path generation
- **Specialized Modules**:
  - `Transform.Sprite`: Sprite sheet generation (native Elixir with FFmpeg)
  - `Transform.Merge`: Clip merging operations (native Elixir with FFmpeg)  
  - `Transform.Split`: Clip splitting operations (native Elixir with FFmpeg)
  - `Transform.Keyframe`: Keyframe extraction (Python OpenCV integration)

### `Clip.Embed` (`lib/heaters/clip/embed.ex`)
- **Purpose**: ML embedding generation and storage
- **States**: `keyframed`, `embedding`, `embedded`
- **Key Functions**: `start_embedding/1`, `complete_embedding/2`, embedding queries

## Worker Organization

Following Elixir/Phoenix best practices, all workers are organized in `lib/heaters/workers/` by domain:

### Video Workers (`lib/heaters/workers/video/`)
- `IngestWorker` - Downloads and processes source videos
- `SpliceWorker` - Splits videos into clips based on scene detection

### Clip Workers (`lib/heaters/workers/clip/`)
- `SpriteWorker` - Generates sprite sheets for review preparation (native Elixir with FFmpeg)
- `MergeWorker` - Merges two clips together (review action, native Elixir with FFmpeg)
- `SplitWorker` - Splits a clip at a specific frame (review action, native Elixir with FFmpeg)  
- `ArchiveWorker` - Cleans up archived clips from S3 and database
- `KeyframeWorker` - Extracts keyframes for embedding generation (Python OpenCV)
- `EmbeddingWorker` - Generates ML embeddings from clip content (Python ML models)

### Orchestration Workers (`lib/heaters/workers/`)
- `Dispatcher` - Batch job orchestration and workflow management

## Orchestration

### Dispatcher (`lib/heaters/workers/dispatcher.ex`)

Runs periodically to find work and enqueue jobs:

1. **Step 1**: Find `new` videos → enqueue `IngestWorker`
2. **Step 2**: Find `spliced` clips → enqueue `SpriteWorker` 
3. **Step 3**: Process pending review actions via `EventProcessor.commit_pending_actions()` (merge/split)
4. **Step 4**: Find `review_approved` clips → enqueue `KeyframeWorker`
5. **Step 5**: Find `review_archived` clips → enqueue `ArchiveWorker`

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

## Key Benefits

1. **Clear Separation**: Media processing (Python) vs business logic (Elixir)
2. **Maintainable**: Each context has focused responsibilities
3. **Scalable**: Independent job processing with proper error handling
4. **Flexible**: Easy to modify workflow or add new processing steps
5. **Reliable**: Comprehensive state management and error recovery
6. **Testable**: Pure functions with predictable inputs/outputs
7. **Environment-Aware**: Automatic dev/prod S3 bucket handling 