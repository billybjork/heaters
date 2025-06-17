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
- `IntakeWorker`: Downloads and processes source videos
- `SpliceWorker`: Splits videos into clips to complete ingestion

**Python Tasks**:
- `intake.py`: Download, re-encode, upload to S3
- `splice.py`: Split video into clips using scene detection

**Process**:
1. Source video created in `new` state
2. `IntakeWorker` transitions to `downloading` → calls `intake.py` → transitions to `downloaded`
3. `SpliceWorker` transitions to `splicing` → calls `splice.py` → transitions to `spliced`
4. Clips created in `spliced` state, `SpriteWorker` jobs enqueued

### 2. Clip Review Preparation (`Clip.Review` Context)

**States**: `spliced` → `generating_sprite` → `pending_review`

**Workers**:
- `SpriteWorker`: Generates sprite sheets for human review

**Python Tasks**:
- `sprite.py`: Generate sprite sheets for frame-by-frame review

**Process**:
1. Clips created in `spliced` state after video splicing
2. `SpriteWorker` transitions to `generating_sprite` → calls `sprite.py` → transitions to `pending_review`
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
- **Workers**: `IntakeWorker`, `SpliceWorker`



### `Clip.Review` (`lib/heaters/clip/review.ex`)
- **Purpose**: Review preparation, human review workflow, and review actions
- **States**: `spliced`, `generating_sprite`, `pending_review`, `review_approved`, `review_archived`
- **Key Functions**: `start_sprite_generation/1`, `complete_sprite_generation/2`, event sourcing functions, review actions
- **Workers**: `SpriteWorker`, `MergeWorker`, `SplitWorker`

### `Clip.Transform` (`lib/heaters/clip/transform.ex`)
- **Purpose**: Post-approval keyframe processing
- **States**: `review_approved`, `keyframing`, `keyframed`
- **Key Functions**: `start_keyframing_from_approved/1`, `complete_keyframing/1`, `create_keyframe_artifacts/2`

### `Clip.Embed` (`lib/heaters/clip/embed.ex`)
- **Purpose**: ML embedding generation and storage
- **States**: `keyframed`, `embedding`, `embedded`
- **Key Functions**: `start_embedding/1`, `complete_embedding/2`, embedding queries

## Worker Organization

### Video Ingestion Workers
- `IntakeWorker` (`lib/heaters/video/ingest/intake_worker.ex`)
- `SpliceWorker` (`lib/heaters/video/ingest/splice_worker.ex`)

### Review Context Workers
- `SpriteWorker` (`lib/heaters/clip/review/sprite_worker.ex`) - Sprite generation
- `MergeWorker` (`lib/heaters/clip/review/merge_worker.ex`) - Review action
- `SplitWorker` (`lib/heaters/clip/review/split_worker.ex`) - Review action

### Post-Approval Workers
- `KeyframeWorker` (`lib/heaters/clip/transform/keyframe_worker.ex`)
- `EmbeddingWorker` (`lib/heaters/clip/embed/embedding_worker.ex`)

### Utility Workers
- `ArchiveWorker` (`lib/heaters/infrastructure/orchestration/archive_worker.ex`)

## Orchestration

### Dispatcher (`lib/heaters/infrastructure/orchestration/dispatcher.ex`)

Runs periodically to find work and enqueue jobs:

1. **Step 1**: Find `new` videos → enqueue `IntakeWorker`
2. **Step 2**: Find `spliced` clips → enqueue `SpriteWorker` 
3. **Step 3**: Process pending review actions (merge/split)
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

## State Transition Rules

### Source Video States
- `new` → `downloading` (via `IntakeWorker`)
- `downloading` → `downloaded` (via `intake.py` success)
- `downloaded` → `splicing` (via `SpliceWorker`)
- `splicing` → `spliced` (via `splice.py` success)

### Clip States
- `spliced` → `generating_sprite` (via `SpriteWorker`)
- `generating_sprite` → `pending_review` (via `sprite.py` success)
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

## Key Benefits

1. **Clear Separation**: Media processing (Python) vs business logic (Elixir)
2. **Maintainable**: Each context has focused responsibilities
3. **Scalable**: Independent job processing with proper error handling
4. **Flexible**: Easy to modify workflow or add new processing steps
5. **Reliable**: Comprehensive state management and error recovery
6. **Testable**: Pure functions with predictable inputs/outputs 