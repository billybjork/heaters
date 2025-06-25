# Heaters Context Refactoring Plan

## Overview

This document outlines the step-by-step plan to refactor the Heaters business logic contexts for better organization, separation of concerns, and adherence to functional programming best practices.

## Current State vs Target State

### Current Structure
```
lib/heaters/clip/
├── review/
│   ├── review.ex              (DOING TOO MUCH)
│   ├── sprite.ex              (MISPLACED - should be in transform/)
│   ├── merge.ex               (MISPLACED - should be in transform/)
│   ├── split.ex               (MISPLACED - should be in transform/)
│   └── clip_event.ex          (MISPLACED - should be in events/)
├── transform.ex               (NEEDS SPLITTING)
├── embed.ex                   (NEEDS REORGANIZING)
└── queries.ex                 (STAYS)
```

### Target Structure
```
lib/heaters/
├── clips.ex                    # Main Clips context entry point
├── clips/
│   ├── clip.ex                # Clip schema
│   ├── queries.ex             # Clip queries
│   ├── review.ex              # Review operations
│   ├── transform.ex           # Transform coordination
│   ├── embed.ex               # Embed operations
│   ├── transform/             # Specialized transform operations
│   │   ├── keyframe.ex
│   │   ├── sprite.ex
│   │   ├── merge.ex
│   │   ├── split.ex
│   │   └── clip_artifact.ex
│   └── embed/                 # Embed domain
│       └── embedding.ex       # Embedding schema
├── videos.ex                  # Main Videos context entry point
├── videos/
│   ├── source_video.ex        # SourceVideo schema
│   ├── queries.ex             # Video queries
│   ├── intake.ex              # Intake operations
│   └── ingest.ex              # Ingest operations
├── events/                    # Event sourcing infrastructure
│   ├── events.ex              # Event creation (writes)
│   ├── event_processor.ex     # Event processing (reads)
│   └── clip_event.ex          # Event schema
└── workers/                   # Background job workers
    ├── dispatcher.ex          # Job orchestration
    ├── clips/                 # Clip-related workers
    │   ├── archive_worker.ex
    │   ├── embedding_worker.ex
    │   ├── keyframe_worker.ex
    │   ├── merge_worker.ex
    │   ├── split_worker.ex
    │   └── sprite_worker.ex
    └── videos/                # Video-related workers
        ├── ingest_worker.ex
        └── splice_worker.ex
```

## Migration Tasks

### Phase 1: Setup and Events Context (Low Risk) ✅ COMPLETE
**Goal**: Create event sourcing infrastructure without breaking existing functionality

#### Task 1.1: Create Events Context Structure
- [x] Create `lib/heaters/events/` directory
- [x] Move `lib/heaters/clip/review/clip_event.ex` to `lib/heaters/events/clip_event.ex`
- [x] Update `clip_event.ex` module name from `Heaters.Clip.Review.ClipEvent` to `Heaters.Events.ClipEvent`
- [x] Update all imports/aliases throughout codebase to use new location

#### Task 1.2: Create Events Context (Write Side)
- [x] Create `lib/heaters/events/events.ex` with functions:
  - [x] `log_review_action(clip_id, action, reviewer_id, event_data \\ %{})`
  - [x] `log_merge_action(target_clip_id, source_clip_id, reviewer_id)`
  - [x] `log_split_action(clip_id, split_frame, reviewer_id)`
  - [x] `log_group_action(target_clip_id, source_clip_id, reviewer_id)`

#### Task 1.3: Create Event Processor (Read Side)
- [x] Create `lib/heaters/events/event_processor.ex` with functions:
  - [x] `commit_pending_actions()` (extracted from current `Clip.Review`)
  - [x] `build_worker_job(event)` (extracted from current `Clip.Review`)
  - [x] `get_unprocessed_events()`
  - [x] `mark_event_processed(event_id)`

#### Task 1.4: Test Events Context
- [x] Write comprehensive tests for `Events` context
- [x] Write comprehensive tests for `EventProcessor` context
- [x] Ensure all existing tests still pass

### Phase 2: Extract Transformation Operations (Medium Risk) ✅ COMPLETE  
**Goal**: Move media transformation operations to appropriate context
**Status**: ✅ Complete - All transformation operations properly organized with native Elixir implementations

#### Task 2.1: Create Transform Context Structure
- [x] Create `lib/heaters/clip/transform/` directory (if not exists)
- [x] Move existing `clip_artifact.ex` to `lib/heaters/clip/transform/clip_artifact.ex` (if needed)

#### Task 2.2: Move Sprite Operations
- [x] Move `lib/heaters/clip/review/sprite.ex` to `lib/heaters/clip/transform/sprite.ex`
- [x] Update module name from `Heaters.Clip.Review.Sprite` to `Heaters.Clip.Transform.Sprite`
- [x] Update all imports/aliases in workers and other modules
- [x] Update `SpriteWorker` to call `Transform.Sprite` instead of `Review.Sprite`

#### Task 2.3: Move Merge Operations
- [x] Move `lib/heaters/clip/review/merge.ex` to `lib/heaters/clip/transform/merge.ex`
- [x] Update module name from `Heaters.Clip.Review.Merge` to `Heaters.Clip.Transform.Merge`
- [x] Update all imports/aliases in workers and other modules
- [x] Update `MergeWorker` to call `Transform.Merge` instead of `Review.Merge`

#### Task 2.4: Move Split Operations ✅ COMPLETE
- [x] Move `lib/heaters/clip/review/split.ex` to `lib/heaters/clip/transform/split.ex`
- [x] Update module name from `Heaters.Clip.Review.Split` to `Heaters.Clip.Transform.Split`
- [x] Update all imports/aliases in workers and other modules
- [x] Update `SplitWorker` to call `Transform.Split` instead of `Review.Split`
- [x] **CRITICAL FIX**: Migrated SplitWorker from `PyRunner.run("split")` to native `Transform.Split.run_split()` (Python script `split.py` didn't exist)

#### Task 2.5: Extract Keyframe Operations ✅ COMPLETE
- [x] Create `lib/heaters/clip/transform/keyframe.ex`
- [x] Extract keyframe-specific functions from `lib/heaters/clip/transform.ex`
- [x] Update `KeyframeWorker` to call `Transform.Keyframe.run_keyframe_extraction()` instead of manual orchestration
- [x] Ensure `Transform` context maintains coordination functions
- [x] **STRATEGIC DECISION**: Keep Python OpenCV integration for keyframe extraction (complex video processing)
- [x] **DOCUMENTATION**: Updated comprehensive documentation for Transform context and specialized modules

#### Task 2.6: Test Transform Context ✅ COMPLETE
- [x] Write/update tests for all moved Transform modules
- [x] Test worker integration with new Transform context
- [x] Ensure all existing functionality works
- [x] **VALIDATION**: Created comprehensive test suites for Transform and Transform.Keyframe modules
- [x] **VALIDATION**: Created worker integration tests for KeyframeWorker
- [x] **VALIDATION**: All modules compile and load correctly
- [x] **VALIDATION**: All functions are properly exported
- [x] **VALIDATION**: All documentation is comprehensive
- [x] **INFRASTRUCTURE**: Created validation script for future refactoring phases

#### Task 2.5.5: Test New Structure ✅ COMPLETE
- [x] Compile project with new structure (`mix compile --warnings-as-errors`)
- [x] Run test suite to ensure all imports work
- [x] Verify Dialyzer passes with new module paths
- [x] Test worker integration with updated paths

#### Task 2.5.6: Reorganize Worker Directories ✅ COMPLETE
- [x] Move `lib/heaters/workers/clip/` to `lib/heaters/workers/clips/` for consistency
- [x] Move `lib/heaters/workers/video/` to `lib/heaters/workers/videos/` for consistency
- [x] Update all worker module names:
  - [x] `Heaters.Workers.Clip.*` → `Heaters.Workers.Clips.*`
  - [x] `Heaters.Workers.Video.*` → `Heaters.Workers.Videos.*`
- [x] Update all references in dispatcher, event processor, and tests
- [x] Remove old singular worker directories
- [x] Verify compilation and type safety with Dialyzer

### Phase 2.5: Idiomatic Directory Structure Reorganization (Medium Risk) ✅ COMPLETE
**Goal**: Reorganize to follow Phoenix/Elixir best practices for context organization
**Status**: ✅ Complete

**Problem**: Current structure has confusing file/directory naming conflicts:
- `clip/transform.ex` + `clip/transform/` directory
- `clip/review.ex` + `clip/review/` directory  
- `clip/embed.ex` + `clip/embed/` directory
- `video/intake.ex` + `video/intake/` directory

**Solution**: Move to idiomatic Phoenix context organization with clear separation.

#### Task 2.5.1: Reorganize Clips Domain ✅ COMPLETE
- [x] Create `lib/heaters/clips/` directory (plural, Phoenix convention)
- [x] Move `lib/heaters/clip/clip.ex` to `lib/heaters/clips/clip.ex` (schema)
- [x] Move `lib/heaters/clip/queries.ex` to `lib/heaters/clips/queries.ex`
- [x] Move `lib/heaters/clip/review.ex` to `lib/heaters/clips/review.ex` (operations)
- [x] Move `lib/heaters/clip/transform.ex` to `lib/heaters/clips/transform.ex` (coordination)
- [x] Move `lib/heaters/clip/embed.ex` to `lib/heaters/clips/embed.ex` (operations)
- [x] Move transform operations to `lib/heaters/clips/transform/`:
  - [x] `clip/transform/keyframe.ex` → `clips/transform/keyframe.ex`
  - [x] `clip/transform/sprite.ex` → `clips/transform/sprite.ex`
  - [x] `clip/transform/merge.ex` → `clips/transform/merge.ex`
  - [x] `clip/transform/split.ex` → `clips/transform/split.ex`
  - [x] `clip/transform/clip_artifact.ex` → `clips/transform/clip_artifact.ex`
- [x] Move embed operations to `lib/heaters/clips/embed/`:
  - [x] `clip/embed/embedding.ex` → `clips/embed/embedding.ex`
- [x] Create main `lib/heaters/clips.ex` context entry point
- [x] Remove old `lib/heaters/clip/` directory

#### Task 2.5.2: Reorganize Videos Domain ✅ COMPLETE
- [x] Create `lib/heaters/videos/` directory (plural, Phoenix convention)
- [x] Move `lib/heaters/video/intake/source_video.ex` to `lib/heaters/videos/source_video.ex` (schema)
- [x] Move `lib/heaters/video/queries.ex` to `lib/heaters/videos/queries.ex`
- [x] Move `lib/heaters/video/intake.ex` to `lib/heaters/videos/intake.ex` (operations)
- [x] Move `lib/heaters/video/ingest.ex` to `lib/heaters/videos/ingest.ex` (operations)
- [x] Create main `lib/heaters/videos.ex` context entry point
- [x] Remove old `lib/heaters/video/` directory

#### Task 2.5.3: Update All Module References ✅ COMPLETE
- [x] Update all module names to use plural contexts:
  - [x] `Heaters.Clip.*` → `Heaters.Clips.*`
  - [x] `Heaters.Video.*` → `Heaters.Videos.*`
- [x] Update all aliases and imports throughout codebase:
  - [x] Workers (`lib/heaters/workers/`)
  - [x] LiveViews (`lib/heaters_web/live/`)
  - [x] Controllers (`lib/heaters_web/controllers/`)
  - [x] Tests (`test/`)
  - [x] Config files if any

#### Task 2.5.4: Update Context Entry Points ✅ COMPLETE
- [x] Create `lib/heaters/clips.ex` with main public API
- [x] Create `lib/heaters/videos.ex` with main public API
- [x] Ensure proper delegation to sub-modules
- [x] Update documentation with new structure

#### Task 2.5.5: Test New Structure ✅ COMPLETE
- [x] Compile project with new structure (`mix compile --warnings-as-errors`)
- [x] Run test suite to ensure all imports work
- [x] Verify Dialyzer passes with new module paths
- [x] Test worker integration with updated paths

**Target Structure After Phase 2.5** ✅ ACHIEVED:
```
lib/heaters/
├── clips.ex                    # Main Clips context entry point
├── clips/
│   ├── clip.ex                # Clip schema
│   ├── queries.ex             # Clip queries
│   ├── review.ex              # Review operations
│   ├── transform.ex           # Transform coordination
│   ├── embed.ex               # Embed operations
│   ├── transform/             # Specialized transform operations
│   │   ├── keyframe.ex
│   │   ├── sprite.ex
│   │   ├── merge.ex
│   │   ├── split.ex
│   │   └── clip_artifact.ex
│   └── embed/                 # Embed domain
│       └── embedding.ex       # Embedding schema
├── videos.ex                  # Main Videos context entry point
├── videos/
│   ├── source_video.ex        # SourceVideo schema
│   ├── queries.ex             # Video queries
│   ├── intake.ex              # Intake operations
│   └── ingest.ex              # Ingest operations
├── events/                    # Event sourcing infrastructure
│   ├── events.ex              # Event creation (writes)
│   ├── event_processor.ex     # Event processing (reads)
│   └── clip_event.ex          # Event schema
└── workers/                   # Background job workers
    ├── dispatcher.ex          # Job orchestration
    ├── clips/                 # Clip-related workers
    │   ├── archive_worker.ex
    │   ├── embedding_worker.ex
    │   ├── keyframe_worker.ex
    │   ├── merge_worker.ex
    │   ├── split_worker.ex
    │   └── sprite_worker.ex
    └── videos/                # Video-related workers
        ├── ingest_worker.ex
        └── splice_worker.ex
```

### Phase 3: Complete Embed Context Organization (Low Risk) ✅ COMPLETE
**Goal**: Complete embed context organization within new idiomatic structure
**Status**: ✅ Complete
**Note**: Most embed reorganization completed in Phase 2.5, finalized in Phase 3

#### Task 3.1: Finalize Embed Context ✅ COMPLETE
- [x] Verify `lib/heaters/clips/embed/` directory structure is complete
- [x] Ensure `lib/heaters/clips/embed.ex` properly coordinates embed operations
- [x] Update any remaining module references in workers and other modules
- [x] Add embed delegations to main `Heaters.Clips` context entry point
- [x] Add missing EmbeddingWorker step to Dispatcher workflow (step 5)
- [x] Verify all embed functions are accessible and properly organized

#### Task 3.2: Test Embed Context ✅ COMPLETE
- [x] Ensure all embed operations continue to work
- [x] Update any broken imports/references
- [x] Test embedding generation workflow end-to-end
- [x] Verify all embed functions are properly exported and delegated
- [x] Validate EmbeddingWorker integration with dispatcher
- [x] Confirm compilation and type safety across all environments

### Phase 4: Refactor Review Context (Medium Risk)
**Goal**: Slim down Review context to focus only on workflow coordination

#### Task 4.1: Extract Sprite State Management ✅ COMPLETE
- [x] Move sprite state management functions from `review.ex` to `transform.ex`:
  - [x] `start_sprite_generation/1`
  - [x] `complete_sprite_generation/2`
  - [x] `mark_sprite_failed/2`
  - [x] `process_sprite_success/2`
  - [x] `build_sprite_prefix/1` (consolidated with `build_artifact_prefix/2`)
- [x] Update `SpriteWorker` to use `Transform` context instead of `Review`
- [x] Keep review-specific query `for_source_video_with_sprites/4` in Review context
- [x] Add sprite functions to main `Clips` context delegation
- [x] Verify compilation and type safety

#### Task 4.2: Update Review Context to Use Events ✅ COMPLETE
- [x] Update `select_clip_and_fetch_next/2` to use `Events.log_review_action/4`
- [x] Update `request_merge_and_fetch_next/2` to use `Events.log_merge_action/3`
- [x] Update `request_split_and_fetch_next/2` to use `Events.log_split_action/3`
- [x] Update `request_group_and_fetch_next/2` to use `Events.log_group_action/3`
- [x] Remove direct event creation logic from Review context
- [x] Add proper error handling for event logging
- [x] Verify compilation and type safety

#### Task 4.3: Update Transform Context Coordination ✅ COMPLETE
- [x] Add state management functions to `transform.ex`:
  - [x] `start_sprite_generation/1` (completed in Task 4.1)
  - [x] `complete_sprite_generation/2` (completed in Task 4.1)
  - [x] `start_keyframing/1`
  - [x] `complete_keyframing/2`
  - [x] `mark_failed/3` (already existed)
- [x] Add shared utility functions:
  - [x] `build_artifact_prefix/2` (already existed)
  - [x] `create_artifacts/2` (already existed)
- [x] Add keyframe convenience functions:
  - [x] `mark_keyframe_failed/2`
- [x] Add keyframe functions to main `Clips` context delegation
- [x] Verify compilation and type safety

#### Task 4.4: Test Refactored Review Context ✅ COMPLETE
- [x] Test review workflow with new Events integration
- [x] Test sprite generation with Transform context
- [ ] Ensure LiveView integration still works (deferred to Phase 6)

### Phase 5: Update Workers and Dependencies (Low Risk)
**Goal**: Update all workers to use new context structure

#### Task 5.1: Update Sprite Worker
- [ ] Update `SpriteWorker` to call `Transform` context for state management
- [ ] Update to call `Transform.Sprite` for operations
- [ ] Test sprite generation workflow end-to-end

#### Task 5.2: Update Merge/Split Workers
- [ ] Update `MergeWorker` to call `Transform.Merge`
- [ ] Update `SplitWorker` to call `Transform.Split`
- [ ] Test merge/split workflows end-to-end

#### Task 5.3: Update Keyframe Worker
- [ ] Update `KeyframeWorker` to call `Transform.Keyframe`
- [ ] Test keyframe extraction workflow

#### Task 5.4: Update Embedding Worker
- [ ] Update `EmbeddingWorker` to use new `Clip.Embed.Embed` location
- [ ] Test embedding generation workflow

#### Task 5.5: Update Dispatcher
  - [x] Update `Dispatcher` to call `EventProcessor.commit_pending_actions()`
- [ ] Remove direct event processing logic
- [ ] Test full workflow orchestration

### Phase 6: Update Frontend and Integration (Low Risk)
**Goal**: Update LiveView and other integration points

#### Task 6.1: Update Review LiveView
- [ ] Update `ReviewLive` imports to use new context locations
- [ ] Test review interface functionality
- [ ] Test merge/split actions from UI

#### Task 6.2: Update Query LiveView
- [ ] Update `QueryLive` to use new `Clip.Embed.Embed` location
- [ ] Test embedding-based query interface

### Phase 7: Documentation and Cleanup (Low Risk)
**Goal**: Update documentation and remove deprecated code

#### Task 7.1: Update README
- [ ] Update `README.md` to reflect new context organization
- [ ] Update context descriptions and responsibilities
- [ ] Update workflow diagrams if any

#### Task 7.2: Code Cleanup
- [ ] Remove any unused functions from old locations
- [ ] Clean up any remaining TODO comments
- [ ] Ensure consistent naming conventions

#### Task 7.3: Test Suite Cleanup
- [ ] Update test file locations to match new structure
- [ ] Ensure 100% test coverage on new contexts
- [ ] Remove any duplicate tests

### Phase 8: Final Validation (Critical)
**Goal**: Comprehensive testing of entire system

#### Task 8.1: End-to-End Testing
- [ ] Test complete video ingestion workflow
- [ ] Test review workflow with all actions (approve, archive, merge, split)
- [ ] Test keyframe and embedding generation
- [ ] Test query interface with embeddings

#### Task 8.2: Performance Testing
- [ ] Ensure no performance regressions
- [ ] Test worker queue performance
- [ ] Test database query performance

#### Task 8.3: Error Handling Testing
- [ ] Test error scenarios in each context
- [ ] Test retry mechanisms
- [ ] Test state recovery after failures

## Dependencies

### Critical Dependencies
- Phase 1 must complete before Phase 4 (Events context needed for Review refactor)
- Phase 2 must complete before Phase 4 (Transform operations moved before Review slim-down)
- Phase 5 depends on Phases 1-4 (Workers need new contexts)

### Parallel Work Opportunities
- Phase 2 and Phase 3 can be done in parallel
- Phase 6 can start after Phase 5 tasks are complete
- Phase 7 can be ongoing throughout the project

## Testing Strategy

### Unit Tests
- [ ] Each new context module has comprehensive unit tests
- [ ] All moved functions maintain existing test coverage
- [ ] New functions have appropriate test coverage

### Integration Tests
- [ ] Worker integration tests updated for new contexts
- [ ] Event sourcing flow tested end-to-end
- [ ] LiveView integration tested

### Regression Tests
- [ ] Existing functionality verified after each phase
- [ ] No breaking changes to external APIs
- [ ] Performance benchmarks maintained

## Rollback Plan

### Safe Rollback Points
1. **After Phase 1**: Events context created but not used - easy rollback
2. **After Phase 2**: Transform operations moved - requires import updates to rollback
3. **After Phase 4**: Major refactor - difficult rollback, ensure thorough testing

### Rollback Considerations
- Keep old code in place during initial phases
- Use feature flags if necessary for gradual rollout
- Maintain backward compatibility where possible

## Success Criteria

### Code Quality
- [ ] Each context has a single, clear responsibility
- [ ] No module exceeds 300 lines of code
- [ ] All functions are pure when possible
- [ ] Clear separation between writes and reads in event sourcing

### Maintainability
- [ ] New team members can easily understand context boundaries
- [ ] Adding new transformation operations is straightforward
- [ ] Event sourcing infrastructure is reusable for other workflows

### Performance
- [ ] No performance regressions in existing workflows
- [ ] Event processing is efficient and scalable
- [ ] Database queries maintain current performance

## Progress Tracking

Use the checkboxes above to track completion. Each completed task should include:
1. Code changes implemented
2. Tests written/updated and passing
3. Integration verified
4. Documentation updated (if applicable)

## Notes

- All changes should maintain backward compatibility until explicitly deprecated
- Consider creating aliases during transition period for critical functions
- Prioritize testing at each phase to catch issues early
- Document any deviations from this plan and rationale 