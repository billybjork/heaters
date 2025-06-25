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
├── events/                    (NEW)
│   ├── events.ex             (Event creation - writes)
│   ├── event_processor.ex    (Event processing - reads/execution)
│   └── clip_event.ex         (Moved from clip/review/)
├── clip/
│   ├── review/
│   │   └── review.ex         (FOCUSED - workflow coordination only)
│   ├── transform/
│   │   ├── transform.ex      (Coordination and shared utilities)
│   │   ├── sprite.ex         (Moved from clip/review/)
│   │   ├── merge.ex          (Moved from clip/review/)
│   │   ├── split.ex          (Moved from clip/review/)
│   │   ├── keyframe.ex       (NEW - extracted from transform.ex)
│   │   └── clip_artifact.ex  (EXISTING)
│   ├── embed/
│   │   └── embed.ex          (Reorganized from clip/embed.ex)
│   └── queries.ex            (UNCHANGED)
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

### Phase 3: Reorganize Embed Context (Low Risk)
**Goal**: Move embed operations to proper directory structure

#### Task 3.1: Create Embed Directory Structure
- [ ] Create `lib/heaters/clip/embed/` directory
- [ ] Move `lib/heaters/clip/embed.ex` to `lib/heaters/clip/embed/embed.ex`
- [ ] Update module references in workers and other modules

#### Task 3.2: Test Embed Context
- [ ] Ensure all embed operations continue to work
- [ ] Update any broken imports/references

### Phase 4: Refactor Review Context (Medium Risk)
**Goal**: Slim down Review context to focus only on workflow coordination

#### Task 4.1: Extract Sprite State Management
- [ ] Move sprite state management functions from `review.ex` to `transform.ex`:
  - [ ] `start_sprite_generation/1`
  - [ ] `complete_sprite_generation/2`
  - [ ] `mark_sprite_failed/2`
  - [ ] `process_sprite_success/2`
  - [ ] `build_sprite_prefix/1`

#### Task 4.2: Update Review Context to Use Events
- [ ] Update `select_clip_and_fetch_next/2` to use `Events.log_review_action/4`
- [ ] Update `request_merge_and_fetch_next/2` to use `Events.log_merge_action/3`
- [ ] Update `request_split_and_fetch_next/2` to use `Events.log_split_action/3`
- [ ] Update `request_group_and_fetch_next/2` to use `Events.log_group_action/3`
- [ ] Remove event creation logic from Review context

#### Task 4.3: Update Transform Context Coordination
- [ ] Add state management functions to `transform.ex`:
  - [ ] `start_sprite_generation/1`
  - [ ] `complete_sprite_generation/2`
  - [ ] `start_keyframing/1`
  - [ ] `complete_keyframing/2`
  - [ ] `mark_failed/3`
- [ ] Add shared utility functions:
  - [ ] `build_artifact_prefix/2`
  - [ ] `create_artifacts/2`

#### Task 4.4: Test Refactored Review Context
- [ ] Test review workflow with new Events integration
- [ ] Test sprite generation with Transform context
- [ ] Ensure LiveView integration still works

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