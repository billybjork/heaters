# Transform Context Refactor Plan

## Overview

This document outlines the step-by-step refactoring of the `Heaters.Clips.Transform` context to eliminate code duplication, improve organization, and create consistent patterns across all transformation operations.

## Current State Analysis

### Problems Identified
1. **Massive Code Duplication** (~400+ lines across modules)
   - Each module has its own `create_temp_directory/0` 
   - Each module has its own S3 download/upload logic
   - Each module has its own result structs with similar fields
   - Each module has its own error handling patterns

2. **Inconsistent State Management**
   - Mixed responsibilities in main `Transform.ex` (351 lines)
   - Each submodule handles state transitions differently
   - Some use main module functions, others implement their own

3. **No Clear Separation of Concerns**
   - Business logic mixed with infrastructure concerns
   - Result structs defined separately in each module
   - Common FFmpeg operations repeated

### Current Structure
```
lib/heaters/clips/transform/
├── transform.ex          # 351 lines - Mixed responsibilities
├── split.ex             # 571 lines - Complete split operations
├── sprite.ex            # 502 lines - Complete sprite generation  
├── keyframe.ex          # 307 lines - Keyframe extraction
├── merge.ex             # 369 lines - Video merging
└── clip_artifact.ex     # 35 lines - Schema only
Total: 2,135 lines
```

## Target Architecture

### New Structure
```
lib/heaters/clips/transform/
├── transform.ex              # ~80 lines - Clean coordination API
├── shared/
│   ├── temp_manager.ex       # ~60 lines - Temp directory operations
│   ├── s3_operations.ex      # ~120 lines - S3 download/upload
│   ├── ffmpeg_runner.ex      # ~100 lines - Common FFmpeg operations
│   └── types.ex              # ~80 lines - All result structs
├── workflows/
│   ├── split_workflow.ex     # ~200 lines - Pure split business logic
│   ├── sprite_workflow.ex    # ~180 lines - Pure sprite business logic  
│   ├── keyframe_workflow.ex  # ~150 lines - Pure keyframe business logic
│   └── merge_workflow.ex     # ~180 lines - Pure merge business logic
└── clip_artifact.ex          # 35 lines - Schema (unchanged)
Estimated Total: ~1,185 lines (950 lines eliminated - 44% reduction)
```

## Implementation Plan

### Phase 1: Create Shared Infrastructure (Steps 1-4)

#### Step 1: Create Types Module
**File**: `lib/heaters/clips/transform/shared/types.ex`
**Goal**: Consolidate all result structs into a single module
**Lines**: ~80
**Benefits**: Eliminate struct duplication, consistent type definitions

**Contents**:
- `TransformResult` - Base result struct
- `SplitResult` - Split operation results
- `SpriteResult` - Sprite generation results
- `KeyframeResult` - Keyframe extraction results
- `MergeResult` - Merge operation results

#### Step 2: Create Temp Manager Module  
**File**: `lib/heaters/clips/transform/shared/temp_manager.ex`
**Goal**: Centralize temporary directory management
**Lines**: ~60
**Benefits**: Eliminate 4 duplicate implementations

**Functions**:
- `create_temp_directory/1` - Create temp dir with optional prefix
- `cleanup_temp_directory/1` - Clean up temp directory
- `with_temp_directory/2` - Execute function with auto-cleanup

#### Step 3: Extend Infrastructure S3 Module
**File**: `lib/heaters/infrastructure/s3.ex` (extend existing)
**Goal**: Add download/upload operations to existing S3 infrastructure
**Lines**: ~80 (added to existing 136 lines)
**Benefits**: Eliminate 4 duplicate S3 implementations, leverage existing infrastructure

**New Functions to Add**:
- `download_file/3` - Download S3 file to local path
- `upload_file/3` - Upload local file to S3  
- `get_bucket_name/0` - Centralize bucket name logic
- `stream_download/3` - Streaming download for large files

#### Step 4: Create FFmpeg Runner Module ✅
**File**: `lib/heaters/clips/transform/shared/ffmpeg_runner.ex` (347 lines)
**Goal**: Centralize common FFmpeg operations
**Lines**: ~100 actual: 347
**Benefits**: Consistent FFmpeg handling, shared encoding options

**Implemented Functions**:
- `create_video_clip/4` - Create video clips with standardized encoding settings
- `create_sprite_sheet/7` - Generate sprite sheets with configurable parameters  
- `merge_videos/2` - Merge videos using FFmpeg concat demuxer
- `get_video_metadata/1` - Extract comprehensive video metadata with ffprobe
- `get_video_fps/1` - Extract video frame rate (simpler version for split operations)
- Common encoding presets and error handling centralized

### Phase 2: Create Workflow Modules (Steps 5-8)

#### Step 5: Create Split Workflow Module ✅
**File**: `lib/heaters/clips/transform/split.ex` (refactored in place, 310 lines)
**Goal**: Pure business logic for split operations  
**Lines**: ~200 actual: 310 (reduced from 571 - **46% reduction**)
**Benefits**: Focus on split-specific logic, use shared infrastructure

**Implemented Changes**:
- ✅ Removed temp directory management (uses `TempManager.with_temp_directory/2`)
- ✅ Removed S3 operations (uses `S3.download_file/3`, `S3.upload_file/3`) 
- ✅ Removed FFmpeg implementation (uses `FFmpegRunner.create_video_clip/4`, `FFmpegRunner.get_video_fps/1`)
- ✅ Removed duplicate SplitResult struct (uses `Types.SplitResult`)
- ✅ Updated `SplitWorker` to use `Types.SplitResult`
- ✅ Kept split-specific validation and business logic

#### Step 6: Create Sprite Workflow Module ✅
**File**: `lib/heaters/clips/transform/sprite.ex` (refactored in place, 192 lines)
**Goal**: Pure business logic for sprite generation
**Lines**: ~180 actual: 192 (reduced from 502 - **62% reduction**)
**Benefits**: Focus on sprite-specific logic, use shared infrastructure

**Implemented Changes**:
- ✅ Removed temp directory management (uses `TempManager.with_temp_directory/2`)
- ✅ Removed S3 operations (uses `S3.download_file/3`, `S3.upload_file/3`)
- ✅ Removed FFmpeg implementation (uses `FFmpegRunner.create_sprite_sheet/7`, `FFmpegRunner.get_video_metadata/1`)
- ✅ Removed duplicate SpriteResult struct (uses `Types.SpriteResult`)
- ✅ Removed duplicate metadata extraction logic (uses shared FFmpegRunner)
- ✅ Updated `Transform.process_sprite_success/2` to use `Types.SpriteResult`
- ✅ Kept sprite-specific parameters and business logic

#### Step 7: Create Keyframe Workflow Module ✅
**File**: `lib/heaters/clips/transform/keyframe.ex` (refactored in place, 151 lines)
**Goal**: Pure business logic for keyframe extraction
**Lines**: ~150 actual: 151 (reduced from 307 - **51% reduction**)
**Benefits**: Focus on keyframe-specific logic, clean Python integration

**Implemented Changes**:
- ✅ Removed artifact creation duplication (uses `Transform.create_artifacts/3`)
- ✅ Removed duplicate error handling (uses `Transform.mark_failed/3`)
- ✅ Removed duplicate S3 prefix logic (uses `Transform.build_artifact_prefix/2`)
- ✅ Removed duplicate KeyframeResult struct (uses `Types.KeyframeResult`)
- ✅ Updated `KeyframeWorker` to use `Types.KeyframeResult`
- ✅ Kept keyframe-specific validation and strategy logic
- ✅ Preserved Python task integration and state transitions

#### Step 8: Create Merge Workflow Module
**File**: `lib/heaters/clips/transform/workflows/merge_workflow.ex`
**Goal**: Pure business logic for merge operations  
**Lines**: ~180 (reduced from 369)
**Benefits**: Focus on merge-specific logic, use shared infrastructure

**Key Changes**:
- Remove temp directory management (use `TempManager`)
- Remove S3 operations (use `S3Operations`)
- Remove FFmpeg implementation (use `FFmpegRunner`) 
- Keep merge-specific validation and clip creation logic

### Phase 3: Refactor Main Module (Step 9)

#### Step 9: Refactor Main Transform Module
**File**: `lib/heaters/clips/transform.ex` 
**Goal**: Clean coordination API that delegates to workflows
**Lines**: ~80 (reduced from 351)
**Benefits**: Clear public API, consistent patterns

**New Structure**:
```elixir
defmodule Heaters.Clips.Transform do
  # Public API - delegates to workflow modules
  defdelegate run_split(clip_id, split_frame), to: SplitWorkflow
  defdelegate run_sprite(clip_id, params), to: SpriteWorkflow  
  defdelegate run_keyframe(clip_id, strategy), to: KeyframeWorkflow
  defdelegate run_merge(target_id, source_id), to: MergeWorkflow
  
  # Shared utilities used by all workflows
  def mark_failed(clip_id, state, reason), do: ...
  def create_artifacts(clip_id, type, data), do: ...
  def build_artifact_prefix(clip, type), do: ...
end
```

### Phase 4: Update Imports and Test (Step 10)

#### Step 10: Update All Imports and Validate
**Goal**: Ensure all existing code continues to work
**Tasks**:
- Update any imports in workers or other modules
- Update test files to use new module structure  
- Run compilation and basic validation
- Verify no breaking changes to public API

## Implementation Guidelines

### Code Quality Standards
1. **No Breaking Changes**: All existing public APIs must continue to work
2. **Comprehensive Logging**: Maintain all existing logging patterns
3. **Error Handling**: Preserve all existing error handling behaviors
4. **Documentation**: Document all new modules and functions
5. **Type Specs**: Include comprehensive `@spec` annotations

### Migration Strategy
1. **Incremental**: Implement one step at a time
2. **Validation**: Test compilation after each step
3. **Backward Compatibility**: Maintain old function exports during transition
4. **Clean Removal**: Remove old implementations only after validation

### Testing Approach
1. **Compilation Test**: Verify all modules compile after each step
2. **Function Export Test**: Verify all expected functions are available
3. **Basic Integration Test**: Test one workflow end-to-end
4. **Regression Test**: Ensure no existing functionality breaks

## Expected Benefits

### Quantitative Improvements
- **Code Reduction**: ~950 lines eliminated (44% reduction)
- **Duplication Elimination**: ~400+ lines of duplicate code removed
- **File Count**: Organized into logical, focused modules
- **Maintainability Score**: Significantly improved

### Qualitative Improvements  
- **Separation of Concerns**: Infrastructure vs business logic clearly separated
- **Consistent Patterns**: All transformations follow same structure
- **Easier Testing**: Infrastructure and business logic can be tested separately
- **Better Documentation**: Each module has focused, clear responsibility
- **Reduced Cognitive Load**: Developers can focus on specific concerns

### Developer Experience
- **Faster Debugging**: Issues isolated to specific modules
- **Easier Feature Addition**: Clear patterns for new transformations
- **Better Code Discovery**: Logical organization makes code easier to find
- **Reduced Onboarding Time**: New developers can understand structure quickly

## Success Criteria

### Phase 1 Success
- [x] All result structs consolidated (Step 1 ✅ - Types module created)
- [x] Temp directory management centralized (Step 2 ✅ - TempManager created)
- [x] S3 operations centralized (Step 3 ✅ - Infrastructure S3 extended)
- [x] FFmpeg operations centralized (Step 4 ✅ - FFmpegRunner created)
- [x] All shared modules created and compiling
- [x] Common operations centralized
- [x] No duplicate utility functions

### Phase 2 Success  
- [ ] All workflow modules created and compiling
- [ ] Business logic separated from infrastructure
- [ ] Each workflow focused on single concern
- [ ] Significant line count reduction achieved

### Phase 3 Success
- [ ] Main Transform module becomes clean facade
- [ ] All public APIs preserved
- [ ] Consistent delegation patterns
- [ ] Clear documentation and examples

### Overall Success
- [ ] Full compilation with no errors
- [ ] All existing tests pass (if any)
- [ ] Public API unchanged (backward compatible)
- [ ] 40%+ code reduction achieved
- [ ] Clean, maintainable architecture established

---

**Next Steps**: Begin with Phase 1, Step 1 - Create the Types module to consolidate all result structs. 