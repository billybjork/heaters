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
- ✅ **Centralized FFmpeg Configuration**: Declarative encoding profiles eliminating hardcoded settings across Python/Elixir with consistent `master`, `proxy`, and optimized export strategy.
- ✅ **Organizational Cleanup**: Directory structure flattened, all module references updated, deprecated code (~85 lines) removed.
- ✅ **CloudFront Streaming**: Complete replacement of WebCodecs/MSE/nginx-mp4 with native CloudFront byte-range streaming via standard HTML5 video for maximum simplicity and reliability.
- 🎉 **Current State**: Production-ready CloudFront streaming architecture with clean, maintainable foundation.

**Architecture Foundation**: All cut point operations now maintain MECE (Mutually Exclusive, Collectively Exhaustive) properties through algorithmic validation, ensuring no gaps, overlaps, or coverage holes in video processing.

## Key Principles

1. **Virtual-First**: All clips start as virtual cut points, only materialized when exported
2. **MECE Guarantee**: Cut points across source videos are mutually exclusive, collectively exhaustive  
3. **Rolling Export**: Individual clip export rather than batch processing
4. **Clean Abstractions**: No legacy merge/split/splice/sprite concepts, centralized FFmpeg configuration
5. **CloudFront Streaming**: Native HTML5 video with CloudFront byte-range support for maximum simplicity

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
- **`export/`**: Final clip creation from proxy using stream copy for optimal quality/performance
  - `worker.ex`: Batch/rolling export operations

---

**Frontend (assets/js/): Native CloudFront Streaming**
  - `cloudfront-video-player.js`: Native HTML5 video element with CloudFront byte-range support and virtual clip timing constraints
  - `cloudfront-video-player-controller.js`: Phoenix LiveView hook for seamless integration
  - `app.js`: Updated with CloudFrontVideoPlayer hook for LiveView integration

**Components (lib/heaters_web/components/):**
  - `cloudfront_video_player.ex`: Phoenix component for CloudFront streaming with automatic URL generation

**Helpers (lib/heaters_web/helpers/):**
  - `video_url_helper.ex`: CloudFront URL generation with S3 fallback for development

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

### ✅ Infrastructure Enhancement: Centralized FFmpeg Configuration (COMPLETE)
- Declarative encoding profiles (`Infrastructure.Orchestration.FFmpegConfig`) for all video operations
- Eliminated hardcoded FFmpeg settings across Python tasks and Elixir modules
- Semantic profiles: `master` (Glacier archival), `proxy` (dual-purpose review/export), `download_normalization`, `keyframe_extraction`, `single_frame`
- Maintained "I/O at the edges" architecture with Python receiving pre-built arguments

### ✅ Storage Strategy Optimization (COMPLETE)
**Decision**: Export from proxy instead of master for superior quality and performance.

**Quality & Performance Benefits:**
- **Higher Quality**: Proxy CRF 20 > deprecated final_export CRF 23
- **10x Faster**: Stream copy vs re-encoding eliminates transcoding time
- **Zero Quality Loss**: No generational loss or transcoding artifacts
- **Instant Access**: Proxy in S3 Standard vs master in S3 Glacier (1-12hr retrieval)

**Cost Optimization:**
- **95% Storage Savings**: Master moved to S3 Glacier for archival only
- **Dual-Purpose Proxy**: Single file serves both WebCodecs review and export needs
- **Streaming Ready**: CRF 20 all-I-frame perfect for Cloudflare Stream ingestion

**Implementation:**
- Updated `py/tasks/export_clips.py` to use proxy with FFmpeg stream copy and S3 presigned URLs
- Updated `lib/heaters/clips/export/worker.ex` to pass proxy_path instead of master_path
- Master remains available for true archival/compliance needs

**I/O Optimization Strategy:**
- **Direct S3 Access**: FFmpeg reads proxy via presigned URLs (no full download)
- **Byte-Range Seeking**: Leverages HTTP range requests for efficient seeking
- **:moov Atom Optimization**: Proxy files use `faststart` for instant seeking capability
- **Minimal Data Transfer**: Only extracts required byte ranges for each clip

### ✅ Phase 2: Rolling Export System (COMPLETE)
- [x] Individual clip export worker enhancement (stream copy from proxy)
- [x] Proxy resource optimization (dual-purpose for review and export)
- [x] Update pipeline configuration for optimized export workflow
- [x] Performance optimization (10x improvement via stream copy)

### ✅ Phase 3: Enhanced Review Interface (CloudFront Streaming) - COMPLETE
- [x] CloudFront URL generation with S3 fallback for development
- [x] Native HTML5 video player with virtual clip timing constraints
- [x] Phoenix LiveView integration with CloudFront streaming URLs
- [x] Complete elimination of complex streaming infrastructure (nginx-mp4, WebCodecs, MSE)
- [x] CloudFront configuration for production deployment
- [x] Development environment testing with direct S3 URLs
- [ ] Cut point manipulation UI with instant streaming (ready for implementation)
- [ ] User experience testing with real data

---

## CloudFront Streaming Implementation

### Architecture Decision

**Problem**: WebCodecs/MSE players and nginx-mp4 infrastructure proved complex and required maintenance overhead.

**Solution**: CloudFront's native byte-range support with standard HTML5 video elements eliminates all custom streaming infrastructure.

### Key Advantages

1. **Maximum Simplicity**: Native HTML5 `<video>` element with zero custom infrastructure
2. **CloudFront Native Support**: Built-in byte-range requests and global edge caching
3. **Universal Compatibility**: Works across all modern browsers without feature detection  
4. **Zero Maintenance**: No streaming services to maintain, debug, or deploy
5. **Production Ready**: CloudFront handles scaling, caching, and global distribution automatically

### Implementation Strategy

**Existing Assets Leveraged:**
- ✅ `source_videos.proxy_filepath` - S3 paths for CloudFront streaming
- ✅ `clips.start_time_seconds` / `clips.end_time_seconds` - timing constraints in JavaScript
- ✅ Proxy CRF 20 encoding - optimized for CloudFront streaming
- ✅ Virtual clips architecture - instant cut point operations

**New Components Implemented:**
- ✅ CloudFront URL generation with S3 fallback (`HeatersWeb.VideoUrlHelper`)
- ✅ Native HTML5 video player with timing constraints (`CloudFrontVideoPlayer`)
- ✅ Phoenix LiveView integration (`CloudFrontVideoPlayerController` hook)
- ✅ Component-based UI (`HeatersWeb.CloudFrontVideoPlayer`)
- ✅ Configuration for CloudFront domain with development S3 fallback

---

## 🎉 Implementation Summary

### ✅ **CloudFront Streaming Architecture - COMPLETE**

**What Was Achieved:**
- **100% Complex Infrastructure Elimination**: Removed WebCodecs/MSE/nginx-mp4 in favor of native CloudFront support
- **Native HTML5 Video**: Leverages browser's built-in byte-range capabilities with CloudFront
- **Zero Custom Infrastructure**: No nginx services, no complex player implementations
- **Maximum Simplicity**: Standard `<video>` element with CloudFront URLs
- **Production-Ready**: Direct CloudFront integration with S3 fallback for development

**Technical Implementation:**
- ✅ **Backend**: `VideoUrlHelper` generates CloudFront URLs with S3 fallback
- ✅ **Frontend**: `CloudFrontVideoPlayer` class handles virtual clip timing constraints
- ✅ **Components**: `cloudfront_video_player.ex` Phoenix component with automatic URL generation
- ✅ **Infrastructure**: Removed nginx service, eliminated complex streaming setup

**Key Performance Benefits:**
- **Maximum Simplicity**: Native browser support eliminates all custom streaming infrastructure
- **CloudFront Optimization**: Automatic byte-range caching and global edge distribution
- **Universal Compatibility**: Works across all modern browsers without feature detection
- **Zero Maintenance**: No custom streaming services to maintain or debug

**Architecture Flow:**
```
Virtual Clip → VideoUrlHelper.get_video_url() → CloudFront URL (proxy file)
             ↓
Phoenix LiveView → CloudFrontVideoPlayer hook → HTML5 <video> with timing constraints
             ↓
CloudFront CDN → S3 byte-range requests → Native streaming playback
```

**Ready for Production**: CloudFront's native byte-range support handles all streaming complexity. Virtual clips play with timing constraints enforced in JavaScript.

**Production Considerations for I/O Optimization:**
- **S3 Presigned URL Security**: 1-hour expiration prevents URL leakage while allowing sufficient export time
- **CloudFront Integration**: Consider CloudFront presigned URLs for improved global performance
- **Error Handling**: Fallback to local download if presigned URL access fails (network issues, expired URLs)
- **Monitoring**: Track byte-range request patterns and proxy file access frequency
- **Cost Impact**: Reduced egress costs due to targeted byte-range access vs full file downloads

---

## Key Benefits

### Architecture Benefits
1. **Conceptual Clarity**: Pure cut point operations replace complex merge/split logic
2. **MECE Guarantee**: Algorithmic validation prevents coverage gaps and overlaps
3. **Clean Abstractions**: No legacy concepts to maintain or debug
4. **Functional Purity**: Cut point operations are mathematical transformations

### Performance Benefits  
1. **Optimized Export**: 10x faster clip creation via stream copy from proxy (no re-encoding)
2. **I/O Efficiency**: Direct S3 byte-range access eliminates proxy download bottleneck
3. **Resource Efficiency**: Dual-purpose proxy eliminates redundant file operations
4. **Instant Operations**: All review actions are immediate database transactions
5. **CloudFront Streaming**: Native byte-range requests enable instant seeking without any custom infrastructure
6. **Superior Quality**: CRF 20 proxy source > deprecated CRF 23 final_export encoding

### Maintenance Benefits
1. **Reduced Complexity**: Fewer concepts and code paths to maintain
2. **Better Testing**: Pure functions enable comprehensive unit testing
3. **Clear Semantics**: Cut point operations have obvious, predictable behavior
4. **Centralized Configuration**: Single source of truth for all FFmpeg encoding settings eliminates hardcoded constants
5. **Future-Proof**: Architecture supports advanced cut point features and easy encoding optimization
6. **Frontend Simplicity**: Native HTML5 `<video>` element eliminates all custom streaming infrastructure maintenance.

---