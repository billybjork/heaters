# Enhanced Virtual Clips Architecture

## Overview

**Goal**: Complete the transition to a pure virtual clip workflow with enhanced cut point management, MECE validation, and rolling export. Eliminate all legacy merge/split/splice/sprite concepts for a clean, maintainable architecture.

### Current Progress Summary

This document tracks the comprehensive refactor of the video processing system's clip management architecture. The system now processes scraped internet videos, splits them into clips using CV-based scene detection, and enables human review for final curation—all using a pure virtual clip workflow.

**Original Challenge**: The legacy system encoded clips during scene detection, making review operations expensive due to re-encoding. Sprite generation for navigation added complexity and storage overhead.

**Solution Approach**: Transition to "virtual clips"—database records with cut points, no physical files until final export. This enables instant review operations, eliminates intermediate file generation, and provides a clean, maintainable foundation.

**Major Work Completed:**
- ✅ **Legacy Code Removal**: All legacy merge/split/splice/sprite code and files fully removed. See "Legacy Code Removal Plan (Historical)" below.
- ✅ **Enhanced VirtualClips Module**: Refactored into focused modules:
  - `virtual_clips/` (core creation/management)
  - `virtual_clips/cut_point_operations.ex` (add/remove/move cut point operations)
  - `virtual_clips/mece_validation.ex` (MECE validation)
  - `virtual_clips/cut_point_operation.ex` (audit trail schema)
- ✅ **Artifacts/Shared Organization**: Artifact utilities moved to `artifacts/operations.ex`. Shared error handling in `shared/error_handling.ex`.
- ✅ **Organizational Cleanup**: Directory structure flattened, all module references updated, deprecated code (~85 lines) removed.
- 🔄 **Current State**: Clean, maintainable foundation ready for Phase 2 (Rolling Export System).

**Architecture Foundation**: All cut point operations now maintain MECE (Mutually Exclusive, Collectively Exhaustive) properties through algorithmic validation, ensuring no gaps, overlaps, or coverage holes in video processing.

## Key Principles

1. **Virtual-First**: All clips start as virtual cut points, only materialized when exported
2. **MECE Guarantee**: Cut points across source videos are mutually exclusive, collectively exhaustive  
3. **Rolling Export**: Individual clip export rather than batch processing
4. **Clean Abstractions**: No legacy merge/split/splice/sprite concepts
5. **WebCodecs Native**: Frame-perfect seeking without sprite dependencies

---

## Core Architecture

### Virtual Clip Lifecycle

```
Source Video: new → download → preprocess → detect_scenes → virtual clips created
                                    ↓
Virtual Clips: pending_review → review_approved → exported (physical) → keyframed → embedded
                    ↓                ↓                ↓
              review_skipped    cut_adjustments   keyframe_failed
                    ↓           (instant DB ops)        ↓
             (terminal)              ↓          (resumable)
                              pending_review
```

### Module Structure (Post-Refactor)

- **`virtual_clips/`**: Virtual clip management
  - `virtual_clips.ex`: Core creation and management
  - `cut_point_operations.ex`: Add/remove/move cut point operations (instant DB transactions)
  - `mece_validation.ex`: MECE validation and coverage checking
  - `cut_point_operation.ex`: Audit trail schema for cut point history
- **`artifacts/`**: Pipeline stages for supplementary data
  - `operations.ex`: Artifact utilities and S3 path management
  - `keyframe/`: Keyframe extraction modules
- **`shared/`**: Cross-context utilities
  - `error_handling.ex`: Centralized error handling and failure tracking
- **`export/`**: Final encoding from gold master to physical clips
  - `worker.ex`: Batch/rolling export operations

### Cut Point Management

All cut point operations are now instant database transactions with full audit trail and MECE validation:
- **Add Cut Point**: Split virtual clip at frame → two new virtual clips, archive original
- **Remove Cut Point**: Merge adjacent virtual clips → new virtual clip, archive originals  
- **Move Cut Point**: Adjust boundaries of adjacent virtual clips
- **MECE Validation**: Ensure no gaps, overlaps, or coverage holes

---

## Enhanced Virtual Clips Operations

### Core Functions

```elixir
# Enhanced VirtualClips module (delegates to focused modules)
defmodule Heaters.Clips.VirtualClips do
  def create_virtual_clips_from_cut_points/3
  def update_virtual_clip_cut_points/2
  defdelegate add_cut_point(source_video_id, frame_number, user_id), to: CutPointOperations
  defdelegate remove_cut_point(source_video_id, frame_number, user_id), to: CutPointOperations
  defdelegate move_cut_point(source_video_id, old_frame, new_frame, user_id), to: CutPointOperations
  defdelegate validate_mece_for_source_video(source_video_id), to: MeceValidation
  defdelegate get_cut_points_for_source_video(source_video_id), to: MeceValidation
  defdelegate ensure_complete_coverage(source_video_id, total_duration), to: MeceValidation
end
```

---

## Review Workflow (Post-Legacy)

1. **Human reviews virtual clips and takes actions:**
   - **approve** → `review_approved` (ready for export)
   - **skip** → `review_skipped` (terminal state)
   - **archive** → `review_archived` (cleanup via archive worker)
   - **group** → group clips for review/metadata purposes
   - **add/remove/move cut point** → instant cut point operations via `VirtualClips.CutPointOperations` → new virtual clips with full audit trail
2. **Actions execute immediately with database transactions, no file re-encoding**
3. **Undo:** Only a simple UI-level undo (e.g., Control+Z) for the most recent action is supported. No buffer/Oban undo or multi-step undo remains.

---

## Legacy Code Removal Plan (Historical)

**Status: Complete.** All legacy code and files listed below have been removed. This section is retained for historical reference only.

### Backend Modules Removed

- All `lib/heaters/clips/edits/merge*` and `split*` modules
- All `lib/heaters/videos/splice*` modules
- All `lib/heaters/clips/artifacts/sprite*` modules

### Frontend Components Removed

- `lib/heaters_web/components/sprite_player.ex`
- `assets/js/sprite-player.js`, `sprite-seeker.js`, and legacy sprite logic in `hover-play.js`

### Database Cleanup

- Sprite artifact types and legacy ingest states removed
- Legacy columns dropped from `source_videos`

### Pipeline Configuration Cleanup

- All legacy merge/split/splice/sprite stages removed from pipeline config
- Only: download → preprocess → detect_scenes → export → keyframes → embeddings remain

---

## Implementation Progress

### ✅ Phase 4: Legacy Code Removal (COMPLETE)
- All legacy code and files removed, directory structure flattened, deprecated code eliminated
- All module references updated to new structure
- All Dialyzer warnings resolved, type safety maintained

### ✅ Phase 1: Enhanced VirtualClips Module (COMPLETE)
- All core cut point operations and MECE validation implemented in focused modules
- Full audit trail for all cut point operations
- Comprehensive test suite for all edge cases

### Phase 2: Rolling Export System (Next)
- [ ] Individual clip export worker enhancement
- [ ] Gold master resource sharing manager
- [ ] Update pipeline configuration for rolling export
- [ ] Performance optimization

### Phase 3: Enhanced Review Interface
- [ ] Cut point manipulation UI with WebCodecs
- [ ] Implement WebCodecs player with fallback
- [ ] Update LiveView event handlers for cut point operations
- [ ] User experience testing

### Phase 5: Production Deployment
- [ ] Gradual rollout with feature flags
- [ ] Performance monitoring
- [ ] User training and documentation
- [ ] Final optimization

---

## Key Benefits

### Architecture Benefits
1. **Conceptual Clarity**: Pure cut point operations replace complex merge/split logic
2. **MECE Guarantee**: Algorithmic validation prevents coverage gaps and overlaps
3. **Clean Abstractions**: No legacy concepts to maintain or debug
4. **Functional Purity**: Cut point operations are mathematical transformations

### Performance Benefits  
1. **Rolling Export**: Faster time-to-delivery for approved clips
2. **Resource Efficiency**: Shared gold master downloads reduce I/O overhead
3. **Instant Operations**: All review actions are immediate database transactions
4. **WebCodecs Native**: Frame-perfect seeking without sprite generation overhead

### Maintenance Benefits
1. **Reduced Complexity**: Fewer concepts and code paths to maintain
2. **Better Testing**: Pure functions enable comprehensive unit testing
3. **Clear Semantics**: Cut point operations have obvious, predictable behavior
4. **Future-Proof**: Architecture supports advanced cut point features

---