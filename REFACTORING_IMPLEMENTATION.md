# Heaters Video Processing Refactoring Implementation

## Overview

This document details the complete implementation of the refactoring that moved database interactions and state management from Python to Elixir, making Python tasks "dumber" and focused solely on media processing.

## Architecture Changes

### Before Refactoring
- **Python handled:** Heavy media processing, database connections/state management, S3 operations, error handling/state transitions, progress logging
- **Elixir handled:** Job orchestration via Oban, high-level state validation, worker dispatch/monitoring

### After Refactoring  
- **Python handles:** Pure media processing (video/image manipulation, ML inference), S3 operations for assets
- **Elixir handles:** ALL database interactions, state management, business logic, error handling, workflow orchestration, progress tracking

## Benefits Achieved

1. **Single Source of Truth** - All state management centralized in Elixir domain contexts
2. **Domain Alignment** - Perfect match with existing context architecture (Video.Ingest, Video.Process, Clip.Transform, Clip.Embed)
3. **Better Error Handling** - Centralized error handling with proper supervision trees
4. **Improved Performance** - Reduced database round trips, transaction-based operations
5. **Enhanced Maintainability** - Clear separation between media processing and business logic
6. **Easier Testing** - Python tasks become pure functions with predictable inputs/outputs

## Implementation Details

### Phase 1: Enhanced Domain Contexts

#### Video.Ingest Context (`lib/heaters/video/ingest.ex`)
- **New Functions:** `start_downloading/1`, `complete_downloading/2`, `start_splicing/1`, `complete_splicing/1`, `mark_failed/3`, `build_s3_prefix/1`
- **Features:** State transition validation, error handling, S3 path management

#### Video.Process Context (`lib/heaters/video/process.ex`) - NEW
- **Functions:** `create_clips_from_splice/2`, `validate_clips_data/1`, `build_s3_prefix/1`
- **Features:** Bulk clip creation with transaction safety, data validation

#### Clip.Transform Context (`lib/heaters/clip/transform.ex`) - NEW
- **Functions:** `start_keyframing/1`, `complete_keyframing/1`, `create_keyframe_artifacts/2`, `start_sprite_generation/1`, `complete_sprite_generation/2`, `mark_failed/3`, `process_keyframe_success/2`, `process_sprite_success/2`
- **Features:** Comprehensive artifact management, transaction-based operations

#### Clip.Embed Context (`lib/heaters/clip/embed.ex`) - ENHANCED
- **New Functions:** `start_embedding/1`, `complete_embedding/2`, `mark_failed/3`, `process_embedding_success/2`
- **Features:** Vector embedding workflow management

### Phase 2: Refactored Workers

All 5 main workers updated to use domain contexts instead of direct database operations:

#### IntakeWorker (`lib/heaters/video/ingest/intake_worker.ex`)
- Uses `Video.Ingest` context for state management
- Passes explicit S3 paths to Python task
- Handles structured return data

#### SpliceWorker (`lib/heaters/video/process/splice_worker.ex`)
- Uses `Video.Ingest` and `Video.Process` contexts
- Processes bulk clip creation from Python results
- Manages scene detection parameters

#### KeyframeWorker (`lib/heaters/clip/transform/keyframe_worker.ex`)
- Uses `Clip.Transform` context
- Manages keyframe artifact creation
- Handles extraction strategy configuration

#### SpriteWorker (`lib/heaters/clip/transform/sprite_worker.ex`)
- Uses `Clip.Transform` context  
- Manages sprite sheet artifact creation
- Handles sprite generation parameters

#### EmbeddingWorker (`lib/heaters/clip/embed/embedding_worker.ex`)
- Uses `Clip.Embed` context
- Manages vector embedding storage
- Retrieves keyframe S3 keys for Python processing

### Phase 3: "Dumber" Python Tasks

Created new refactored versions of all Python tasks that focus solely on media processing:

#### `python/tasks/intake_refactored.py`
- **Purpose:** Download, re-encode, and upload videos
- **Input:** `run_intake(source_video_id, input_source, output_s3_prefix, re_encode_for_qt, **kwargs)`
- **Output:** `{"status": "success", "s3_key": "...", "metadata": {...}}`
- **Removed:** Database connections, state management

#### `python/tasks/splice_refactored.py`
- **Purpose:** Scene detection and video splitting
- **Input:** `run_splice(source_video_id, input_s3_path, output_s3_prefix, detection_params, **kwargs)`
- **Output:** `{"status": "success", "clips": [...], "metadata": {...}}`
- **Features:** OpenCV-based scene detection, FFmpeg video processing
- **Removed:** Database connections, clip record creation

#### `python/tasks/keyframe_refactored.py`
- **Purpose:** Extract keyframes from video clips
- **Input:** `run_keyframe(clip_id, input_s3_path, output_s3_prefix, strategy, **kwargs)`
- **Output:** `{"status": "success", "artifacts": [...], "metadata": {...}}`
- **Features:** Multiple extraction strategies (midpoint, multi), OpenCV frame extraction
- **Removed:** Database connections, artifact record creation

#### `python/tasks/sprite_refactored.py`
- **Purpose:** Generate sprite sheets from video clips
- **Input:** `run_sprite(clip_id, input_s3_path, output_s3_prefix, overwrite, **kwargs)`
- **Output:** `{"status": "success", "artifacts": [...], "metadata": {...}}`
- **Features:** FFmpeg-based sprite generation, configurable grid layout
- **Removed:** Database connections, artifact record creation

#### `python/tasks/embed_refactored.py`
- **Purpose:** Generate ML embeddings from keyframe images
- **Input:** `run_embed(clip_id, keyframe_s3_keys, model_name, generation_strategy, device, **kwargs)`
- **Output:** `{"status": "success", "model_name": "...", "embedding": [...], "metadata": {...}}`
- **Features:** CLIP/DINOv2 model support, embedding aggregation, model caching
- **Removed:** Database connections, embedding record creation

#### `python/tasks/archive_refactored.py`
- **Purpose:** Delete S3 objects for cleanup operations
- **Input:** `run_archive(s3_keys_to_delete, **kwargs)`
- **Output:** `{"status": "success", "deleted_count": N, "error_count": N, "errors": [...]}`
- **Features:** Batch deletion (1000 objects per request), error handling
- **Removed:** Database connections (was already minimal)

#### `python/tasks/merge_refactored.py`
- **Purpose:** Merge two video clips into one
- **Input:** `run_merge(target_clip_id, source_clip_id, target_s3_path, source_s3_path, output_s3_prefix, merge_metadata, **kwargs)`
- **Output:** `{"status": "success", "merged_clip": {...}, "metadata": {...}}`
- **Features:** FFmpeg concatenation, progress reporting
- **Removed:** Database connections, clip record management, artifact cleanup

#### `python/tasks/split_refactored.py`
- **Purpose:** Split a video clip into two at a specific frame
- **Input:** `run_split(clip_id, source_video_s3_path, output_s3_prefix, split_params, **kwargs)`
- **Output:** `{"status": "success", "original_clip_id": N, "created_clips": [...], "metadata": {...}}`
- **Features:** Frame-accurate splitting, FFmpeg processing, duration validation
- **Removed:** Database connections, clip record creation, artifact cleanup

## Common Python Task Features

All refactored Python tasks share these characteristics:

1. **Clear Documentation:** Header describing purpose and approach
2. **Explicit Parameters:** All S3 paths and configuration passed from Elixir
3. **Structured Returns:** Consistent JSON response format with status, data, and metadata
4. **No Database Dependencies:** Removed all psycopg2 imports and database connections
5. **Progress Reporting:** S3 transfer progress callbacks for large files
6. **Error Handling:** Comprehensive exception handling with structured error responses
7. **Standalone Execution:** Command-line interface for testing and debugging

## State Transition Management

### Source Video States
- `new` → `downloading` → `downloaded` → `splicing` → `spliced`
- Error states: `ingestion_failed`, `splicing_failed`

### Clip States  
- `new` → `spliced` → `keyframing` → `keyframed` → `generating_sprite` → `pending_review` → `embedded`
- Error states: `keyframing_failed`, `sprite_failed`, `embedding_failed`

All state transitions now managed exclusively in Elixir domain contexts with proper validation.

## Data Flow

### Video Ingestion Flow
1. **Elixir:** `Video.Ingest.start_downloading/1` - Update state to `downloading`
2. **Python:** `intake_refactored.py` - Download, process, upload video
3. **Elixir:** `Video.Ingest.complete_downloading/2` - Update state to `downloaded`, store S3 path

### Video Processing Flow  
1. **Elixir:** `Video.Ingest.start_splicing/1` - Update state to `splicing`
2. **Python:** `splice_refactored.py` - Scene detection, create clips, upload to S3
3. **Elixir:** `Video.Process.create_clips_from_splice/2` - Bulk create clip records

### Clip Processing Flow
1. **Elixir:** `Clip.Transform.start_keyframing/1` - Update state to `keyframing`
2. **Python:** `keyframe_refactored.py` - Extract keyframes, upload to S3
3. **Elixir:** `Clip.Transform.process_keyframe_success/2` - Create artifacts, update state
4. **Elixir:** `Clip.Transform.start_sprite_generation/1` - Update state to `generating_sprite`
5. **Python:** `sprite_refactored.py` - Generate sprite sheet, upload to S3
6. **Elixir:** `Clip.Transform.process_sprite_success/2` - Create artifacts, update state
7. **Elixir:** `Clip.Embed.start_embedding/1` - Update state to `embedding`
8. **Python:** `embed_refactored.py` - Generate embeddings from keyframes
9. **Elixir:** `Clip.Embed.process_embedding_success/2` - Store embedding, update state

## Technical Implementation Notes

### Transaction Safety
- All database operations wrapped in transactions
- Proper rollback handling for errors
- Advisory locks for critical sections

### Error Handling
- Comprehensive error propagation from Python to Elixir
- Structured error responses with error types
- Failed state management with retry capabilities

### Performance Optimizations
- Bulk operations for clip creation
- Reduced database round trips
- Model caching in Python for ML tasks
- S3 transfer progress reporting

### Idempotency
- All workers check current state before processing
- Overwrite flags for reprocessing scenarios
- Artifact cleanup for overwrites

## File Structure

```
lib/heaters/
├── video/
│   ├── ingest.ex (enhanced)
│   ├── process.ex (new)
│   └── ingest/intake_worker.ex (refactored)
│   └── process/splice_worker.ex (refactored)
├── clip/
│   ├── transform.ex (new)
│   ├── embed.ex (enhanced)
│   ├── queries.ex (enhanced)
│   └── transform/keyframe_worker.ex (refactored)
│   └── transform/sprite_worker.ex (refactored)
│   └── embed/embedding_worker.ex (refactored)

python/tasks/
├── intake_refactored.py (new)
├── splice_refactored.py (new)  
├── keyframe_refactored.py (new)
├── sprite_refactored.py (new)
├── embed_refactored.py (new)
├── archive_refactored.py (new)
├── merge_refactored.py (new)
└── split_refactored.py (new)
```

## Cleanup Status

✅ **Phase 1 Complete**: Enhanced domain contexts with state management functions
✅ **Phase 2 Complete**: Refactored all workers to use domain contexts  
✅ **Phase 3 Complete**: Created "dumber" Python tasks focused on media processing
✅ **Cleanup Complete**: Removed original files, renamed refactored tasks, updated dependencies

**Cleanup Actions Completed:**
- ✅ Removed all original Python task files (intake.py, splice.py, keyframe.py, sprite.py, embed.py, merge.py, split.py, archive.py)
- ✅ Renamed all refactored files (removed `_refactored` suffix)
- ✅ Removed `python/utils/db.py` (no longer needed for database connections)
- ✅ Updated `python/requirements.txt` (removed psycopg2-binary and SQLAlchemy dependencies)
- ✅ Verified Python imports and runner.py functionality with renamed modules

**Ready for Production:**
The refactored system is now ready for testing and deployment. All Python tasks are focused on media processing, all business logic is centralized in Elixir domain contexts, and the codebase is cleaned of legacy database connection code.

## Summary

The refactoring successfully achieved the goal of making Python tasks "dumber" and focused on media processing while centralizing all business logic and state management in Elixir. This creates a more maintainable, testable, and reliable system with clear separation of concerns. 