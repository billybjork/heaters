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
- ✅ **Infrastructure Foundation**: Complete elimination of complex streaming infrastructure (WebCodecs/MSE/nginx-mp4) and establishment of clean virtual clips architecture.
- ✅ **Server-Side Time Segmentation**: FFmpeg-based streaming infrastructure implemented with database-level MECE constraints, process pooling, and rate limiting.

**Architecture Foundation**: All cut point operations now maintain MECE (Mutually Exclusive, Collectively Exhaustive) properties through algorithmic validation, ensuring no gaps, overlaps, or coverage holes in video processing.

## Key Principles

1. **Virtual-First**: All clips start as virtual cut points, only materialized when exported
2. **MECE Guarantee**: Cut points across source videos are mutually exclusive, collectively exhaustive  
3. **Rolling Export**: Individual clip export rather than batch processing
4. **Clean Abstractions**: No legacy merge/split/splice/sprite concepts, centralized FFmpeg configuration
5. **Server-Side Time Segmentation**: FFmpeg-based streaming that serves only the exact time ranges needed for virtual clips

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

**Frontend (assets/js/): Server-Side Time Segmentation**
  - `cloudfront-video-player.js`: Standard HTML5 video element for FFmpeg-segmented streams
  - `cloudfront-video-player-controller.js`: Phoenix LiveView hook for seamless integration
  - `app.js`: Updated with CloudFrontVideoPlayer hook for LiveView integration

**Controllers (lib/heaters_web/controllers/):**
  - `video_controller.ex`: FFmpeg-based streaming endpoint for virtual clips

**Components (lib/heaters_web/components/):**
  - `cloudfront_video_player.ex`: Phoenix component for streaming URL generation

**Helpers (lib/heaters_web/helpers/):**
  - `video_url_helper.ex`: Streaming endpoint URL generation with signed CloudFront URLs  
  - `stream_ports.ex`: FFmpeg stdout streaming with zombie process protection
  - `ffmpeg_pool.ex`: Process pool with ETS-based rate limiting

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

### ✅ Phase 3: Server-Side Time Segmentation (COMPLETE - Stage 1)
- [x] **Infrastructure foundation** and complex streaming elimination 
- [x] **Virtual clips architecture** and database schema alignment
- [x] **Database MECE constraints** with PostgreSQL EXCLUDE using GIST indexes
- [x] **FFmpeg streaming endpoint** (`/videos/clips/:clip_id/stream/:version`) with rate limiting
- [x] **StreamPorts helper** for efficient FFmpeg stdout streaming with zombie protection
- [x] **FFmpeg process pool** with ETS counters and graceful degradation
- [x] **VideoUrlHelper updates** to generate signed CloudFront URLs for FFmpeg input
- [x] **Application supervision** integration for process pool management
- [ ] **Router configuration** for streaming endpoints  
- [ ] **Component integration** with new streaming approach
- [ ] **CloudFront integration** as caching layer for FFmpeg output
- [ ] Cut point manipulation UI with instant streaming
- [ ] User experience testing with real data

---

## Server-Side Time Segmentation Implementation

### Architecture Decision

**Problem**: Traditional byte-range streaming downloads entire video files before playing specific time segments, wasting bandwidth and time.

**Solution**: Server-side FFmpeg time segmentation that streams only the exact bytes needed for each virtual clip, with CloudFront as a caching layer.

### Key Advantages

1. **True Virtual Clips**: Only streams the exact time range requested, not the full video
2. **FFmpeg Precision**: Keyframe-accurate seeking with proper MP4 headers (`-c copy -movflags +faststart`)
3. **CloudFront Caching**: Phoenix acts as custom origin, CloudFront caches segmented output globally
4. **Zero Client Complexity**: Standard HTML5 `<video>` element receives complete MP4 fragments
5. **Bandwidth Efficient**: Dramatically reduces data transfer compared to full-file streaming

### Implementation Strategy

**Database Schema Alignment:**
- ✅ `clips.start_time_seconds` / `clips.end_time_seconds` - Used directly by FFmpeg `-ss` and `-to` parameters
- ✅ `clips.is_virtual` flag - Determines streaming vs direct file access
- ✅ `source_videos.proxy_filepath` - Provides signed CloudFront URLs for FFmpeg input
- ✅ Virtual clips architecture - Perfect for on-demand segmentation

**Core Implementation Components:**

#### 1. **FFmpeg Streaming Endpoint**
```elixir
# GET /videos/clips/:clip_id/stream
def stream_clip(conn, %{"clip_id" => clip_id}) do
  clip = get_clip_with_source_video(clip_id)
  signed_url = generate_signed_url(clip.source_video.proxy_filepath)
  
  cmd = ~w(ffmpeg -hide_banner -loglevel error
           -ss #{clip.start_time_seconds}
           -to #{clip.end_time_seconds}  
           -i #{signed_url}
           -c copy -movflags +faststart -f mp4 pipe:1)
  
  conn
  |> put_resp_header("content-type", "video/mp4")
  |> put_resp_header("accept-ranges", "bytes")
  |> put_resp_header("cache-control", "public, max-age=31536000")
  |> send_chunked(200)
  |> StreamPorts.stream(cmd)
end
```

#### 2. **StreamPorts Helper**
```elixir
defmodule HeatersWeb.StreamPorts do
  def stream(conn, cmd) do
    port = Port.open({:spawn_executable, System.find_executable("ffmpeg")}, 
                     [:binary, :exit_status, args: tl(cmd)])
    stream_port_output(conn, port)
  end
  
  defp stream_port_output(conn, port) do
    # Stream FFmpeg stdout directly to chunked HTTP response
  end
end
```

#### 3. **URL Generation Updates**
```elixir
# HeatersWeb.VideoUrlHelper
def get_video_url(%{is_virtual: true} = clip, _source_video) do
  streaming_url = ~p"/videos/clips/#{clip.id}/stream"
  {:ok, streaming_url, :ffmpeg_stream}
end
```

#### 4. **Router Configuration**
```elixir
# router.ex
scope "/videos", HeatersWeb do
  get "/clips/:clip_id/stream", VideoController, :stream_clip
end
```

---

## 🚧 Implementation Plan: Server-Side Time Segmentation

### **Current Goal: True Virtual Clip Streaming**

**What We're Building:**
- **FFmpeg-Based Streaming**: Server-side time segmentation that streams only exact clip ranges
- **Phoenix as Custom Origin**: CloudFront caches FFmpeg output for global distribution
- **Zero Client Downloads**: Browsers receive complete MP4 fragments, not full source videos
- **Keyframe Accuracy**: FFmpeg ensures proper video headers and keyframe alignment

### **Implementation Stages**

#### **✅ Stage 1: Core Streaming Infrastructure** (**COMPLETE**)
- [x] **Database MECE Constraints** (`20250728234518_add_mece_overlap_constraints.exs`)
  ```sql
  ALTER TABLE clips
    ADD CONSTRAINT clips_no_virtual_overlap
    EXCLUDE USING gist (
       source_video_id WITH =,
       numrange(
         start_time_seconds::numeric,
         end_time_seconds::numeric,
         '[)'
       ) WITH &&
    ) WHERE (is_virtual = true);
  ```
- [x] **StreamPorts Helper** (`lib/heaters_web/helpers/stream_ports.ex`)
  - Port management with `Port.monitor/1` for zombie cleanup  
  - Chunked HTTP response handling with backpressure
  - `Plug.Conn.register_before_send` cleanup on connection drops
  - Proper FFmpeg process termination with "q" command and SIGTERM fallback
  - Configurable 5-minute timeout for large clips
- [x] **FFmpeg Process Pool** (`lib/heaters_web/helpers/ffmpeg_pool.ex`) 
  - ETS counter for active processes with write concurrency
  - Rate limiting (429 response when > max workers)
  - Graceful degradation with process count rollback
  - Integrated into application supervision tree
  - Periodic cleanup and monitoring logs
- [x] **FFmpeg Streaming Endpoint** (`lib/heaters_web/controllers/video_controller.ex`)
  - `/videos/clips/:clip_id/stream/:version` route with cache versioning
  - Clip lookup with source video preloading via `Repo.preload/2`
  - FFmpeg command: `-ss START -to END -i SIGNED_URL -c copy -movflags +faststart -f mp4 pipe:1`
  - Response headers optimized for CloudFront caching (`max-age=31536000`)
  - Virtual clip validation (only `is_virtual: true` clips can be streamed)

#### **🚧 Stage 2: URL Generation & Routing** (**NEXT**)
- [x] **VideoUrlHelper Updates** (`lib/heaters_web/helpers/video_url_helper.ex`)
  - Added `generate_signed_cloudfront_url/1` for FFmpeg input URLs
  - Supports development (presigned S3) and production (CloudFront) modes
  - Longer expiration times optimized for video processing
  - ~~Generate versioned streaming URLs~~ (handled in controller routing)
  - ~~Version based on `clips.updated_at`~~ (URL versioning via route parameters)
- [ ] **Router Configuration** (`lib/heaters_web/router.ex`)
  - Add versioned streaming routes: `get "/clips/:clip_id/stream/:version"`
  - Optional authentication middleware for streaming endpoints

#### **Stage 3: Component Integration**
- [ ] **CloudFront Player Updates** (`assets/js/cloudfront-video-player.js`)
  - Handle streaming URLs vs direct URLs
  - Remove timing constraints (now handled server-side)  
  - Add `preload="metadata"` for complete MP4 fragments
  - Implement 200ms debouncing for timeline scrubbing
  - Add subtle loading spinner (~150ms FFmpeg startup latency)
- [ ] **Component Updates** (`lib/heaters_web/components/cloudfront_video_player.ex`)
  - Update to use versioned URL generation
  - Simplify component logic (no client-side timing)

#### **Stage 4: Production Optimization**
- [ ] **CloudFront Configuration Tuning**
  - **Cache Policy**: `CachingOptimized` (Range-aware, automatic)
  - **Origins**: Phoenix (streaming) + S3 (exported files)  
  - **TTL**: 5min-1h for previews, ≥1 year for exports
  - **CORS**: `Access-Control-Allow-Origin` for cross-domain UI
- [ ] **Keyframe Leakage Handling** (if needed)
  - Detect problematic clips with visible pre-roll
  - Implement precision mode: `-ss -to -copyts -avoid_negative_ts 1 -c:v libx264 -preset ultrafast`
  - Apply only to first/last 1-2 seconds of clips
- [ ] **Performance Monitoring**
  - FFmpeg process count and memory usage
  - Stream latency measurement (~150ms startup)
  - CloudFront cache hit ratios
  - Database constraint violation tracking

### **Architecture Flow (✅ Implemented)**
```
Virtual Clip Request → Phoenix Endpoint → FFmpeg Process Pool (Rate Limiting)
                                                    ↓
                       FFmpeg Time Segmentation → StreamPorts (Zombie Protection)
                                                    ↓
                            Chunked Stream → Browser <video> element
                                  ↓
               CloudFront Caching ← MP4 Fragment ← stdout stream (Ready for Stage 2)
```

### **Benefits Achieved (Stage 1)**
- ✅ **Database Integrity**: MECE constraints prevent overlapping virtual clips at database level
- ✅ **Process Safety**: Zombie FFmpeg process prevention with port monitoring and cleanup
- ✅ **Resource Protection**: Rate limiting prevents server overload during concurrent streaming
- ✅ **True Virtual Clips**: FFmpeg streams only exact time ranges, eliminating full video downloads
- ✅ **Production Ready**: Supervision tree integration with graceful error handling

### **Benefits Pending (Stage 2+)**  
- **CloudFront Caching**: Identical clips cached globally for subsequent requests
- **Simple Maintenance**: Standard Elixir/Phoenix patterns, no complex streaming infrastructure
- **Bandwidth Efficiency**: ~90% reduction in data transfer (2-minute clip vs 60-minute source) 
- **Instant Playback**: No waiting for full video download

### **Key Implementation Notes**

#### **FFmpeg Configuration**
- **Input Seeking (`-ss`)**: Applied before input for keyframe-accurate positioning
- **Stream Copy (`-c copy`)**: Zero re-encoding for maximum speed and quality
- **Fast Start (`-movflags +faststart`)**: Moves moov atom to front for instant playback
- **Pipe Output (`-f mp4 pipe:1`)**: Streams complete MP4 fragments to stdout
- **Keyframe Leakage**: Stream copy snaps to nearest earlier keyframe (may show pre-roll)
- **Precision Mode** (if needed): `-ss -to -copyts -avoid_negative_ts 1 -c:v libx264 -preset ultrafast`

#### **CloudFront Configuration** 
- **Origin**: Phoenix app as custom origin (not direct S3)
- **Cache Policy**: `CachingOptimized` - automatically handles Range headers
- **Allowed Methods**: GET & HEAD only
- **Cache Duration**: Long TTL appropriate for immutable clip content
- **CORS**: Add `Access-Control-Allow-Origin` for cross-domain requests

#### **Performance Considerations**
- **Concurrency**: One FFmpeg process per active reviewer scales well on modern hardware
- **Memory Usage**: Streaming approach keeps memory footprint minimal
- **CPU Impact**: Stream copy typically <10% CPU usage on t4g.medium instances
- **Zombie Process Prevention**: `Port.monitor/1` + `Process.exit/2` on connection drops
- **Rate Limiting**: ETS counter with 429 response when > N active workers
- **Cache Versioning**: Include clip version in URL to bust CloudFront cache on edits

#### **Database Query Optimization**
```elixir
# Preload source video to avoid N+1 queries
clip = 
  Clip
  |> Repo.get!(clip_id)
  |> Repo.preload(:source_video)
```

#### **StreamPorts Implementation Details**
```elixir
# Key patterns for robust FFmpeg streaming
Port.open({:spawn_executable, ffmpeg_bin}, [
  :binary, 
  {:args, args}, 
  :stderr_to_stdout, 
  :exit_status
])

# Cleanup patterns:
# 1. Monitor port for zombie prevention
# 2. before_send callback for connection drops
# 3. Proper SIGTERM on errors
```

#### **Security Considerations**
- **FFmpeg Input**: Use signed CloudFront URLs (not S3) for edge caching
- **Streaming Auth**: Session cookies or 5-minute HMAC tokens
- **Public Thumbnails**: Keep small preview images public (no signing overhead)
- **Rate Limiting**: Prevent FFmpeg process floods with ETS counters

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
5. **Server-Side Time Segmentation**: FFmpeg streams only exact clip ranges, eliminating full-video downloads
6. **Superior Quality**: CRF 20 proxy source > deprecated CRF 23 final_export encoding

### Maintenance Benefits
1. **Reduced Complexity**: Fewer concepts and code paths to maintain
2. **Better Testing**: Pure functions enable comprehensive unit testing
3. **Clear Semantics**: Cut point operations have obvious, predictable behavior
4. **Centralized Configuration**: Single source of truth for all FFmpeg encoding settings eliminates hardcoded constants
5. **Future-Proof**: Architecture supports advanced cut point features and easy encoding optimization
6. **Frontend Simplicity**: Standard HTML5 `<video>` element with server-side segmentation eliminates client-side complexity.

---