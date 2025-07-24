# Enhanced Virtual Clips Architecture

## Overview

**Goal**: Complete the transition to a pure virtual clip workflow with enhanced cut point management, MECE validation, and rolling export. Eliminate legacy merge/split/splice/sprite concepts entirely for a clean, maintainable architecture.

### Current Progress Summary

This document represents a comprehensive refactor of a video processing system's clip management architecture. The system processes scraped internet videos, splits them into clips using CV-based scene detection, and enables human review for final curation.

**Original Challenge**: The legacy system immediately encoded clips during scene detection, making human review operations (merge/split adjustments) expensive due to re-encoding requirements. Sprite generation for frame-by-frame navigation added complexity and storage overhead.

**Solution Approach**: Transition to "virtual clips" - database records with cut points but no physical files until final export. This enables instant review operations and eliminates intermediate file generation.

**Major Work Completed This Session**:
- ✅ **Legacy Code Removal (Phase 4)**: Systematically removed ~42 files of legacy merge/split/splice/sprite functionality, achieving complete clean slate
- ✅ **Enhanced VirtualClips Module (Phase 1)**: Implemented mathematically sound cut point operations with MECE validation, comprehensive audit trail, and database schema enhancements
- ✅ **Organizational Cleanup**: Flattened directory structure by removing `operations/` layer from both `clips/` and `videos/` contexts, updated all module references
- 🔄 **Current State**: Clean, maintainable foundation ready for Phase 2 (Rolling Export System) implementation

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

### Cut Point Management

**Central Concept**: All cut point operations maintain MECE properties across the source video:

- **Add Cut Point**: Split virtual clip at frame → two new virtual clips, archive original
- **Remove Cut Point**: Merge adjacent virtual clips → new virtual clip, archive originals  
- **Move Cut Point**: Adjust boundaries of adjacent virtual clips
- **MECE Validation**: Ensure no gaps, overlaps, or coverage holes

---

## Enhanced Virtual Clips Operations

### Core Functions

```elixir
# Enhanced VirtualClips module
defmodule Heaters.Clips.VirtualClips do
  
  # Current functions (keep)
  def create_virtual_clips_from_cut_points/3
  def update_virtual_clip_cut_points/2
  
  # New source-level cut point management
  def add_cut_point(source_video_id, frame_number, user_id)
  def remove_cut_point(source_video_id, frame_number, user_id)  
  def move_cut_point(source_video_id, old_frame, new_frame, user_id)
  
  # MECE validation and management
  def validate_mece_for_source_video(source_video_id)
  def get_cut_points_for_source_video(source_video_id)
  def ensure_complete_coverage(source_video_id, total_duration)
  
  # Legacy operations (remove these entirely)
  # - No merge_clips function
  # - No split_clip function  
  # - These are replaced by add/remove/move cut point operations
end
```

### Cut Point Operations Design

#### Add Cut Point
```elixir
def add_cut_point(source_video_id, frame_number, user_id) do
  Repo.transaction(fn ->
    # 1. Find virtual clip that contains this frame
    case find_virtual_clip_containing_frame(source_video_id, frame_number) do
      {:ok, target_clip} ->
        # 2. Validate frame is not at clip boundaries (no-op)
        case validate_split_frame(target_clip, frame_number) do
          :ok ->
            # 3. Create two new virtual clips from split
            {first_cut_points, second_cut_points} = 
              split_cut_points_at_frame(target_clip.cut_points, frame_number)
            
            # 4. Create new clips and archive original
            create_split_clips_and_archive_original(
              source_video_id, [first_cut_points, second_cut_points], target_clip, user_id
            )
            
          {:error, reason} -> 
            Repo.rollback(reason)
        end
        
      {:error, reason} ->
        Repo.rollback(reason)
    end
  end)
end
```

#### Remove Cut Point
```elixir  
def remove_cut_point(source_video_id, frame_number, user_id) do
  Repo.transaction(fn ->
    # 1. Find two adjacent clips that share this cut point
    case find_adjacent_clips_at_frame(source_video_id, frame_number) do
      {:ok, {first_clip, second_clip}} ->
        # 2. Combine their cut points
        merged_cut_points = combine_adjacent_cut_points(
          first_clip.cut_points, second_clip.cut_points
        )
        
        # 3. Create new merged clip and archive originals
        create_merged_clip_and_archive_originals(
          source_video_id, merged_cut_points, [first_clip, second_clip], user_id
        )
        
      {:error, reason} ->
        Repo.rollback(reason)
    end
  end)
end
```

### MECE Validation

```elixir
defp validate_mece_for_source_video(source_video_id, total_duration_seconds) do
  virtual_clips = get_virtual_clips_for_source(source_video_id)
  cut_points_list = Enum.map(virtual_clips, & &1.cut_points)
  
  with :ok <- ensure_no_overlaps(cut_points_list),
       :ok <- ensure_no_gaps(cut_points_list),
       :ok <- ensure_complete_coverage(cut_points_list, total_duration_seconds) do
    :ok
  else
    {:error, reason} -> {:error, reason}
  end
end

defp ensure_no_overlaps(cut_points_list) do
  sorted_clips = Enum.sort_by(cut_points_list, &(&1["start_time_seconds"]))
  
  case find_overlap_in_sorted_clips(sorted_clips) do
    nil -> :ok
    overlap -> {:error, "Overlap detected: #{inspect(overlap)}"}
  end
end

defp ensure_no_gaps(cut_points_list) do
  sorted_clips = Enum.sort_by(cut_points_list, &(&1["start_time_seconds"]))
  
  case find_gap_in_sorted_clips(sorted_clips) do
    nil -> :ok  
    gap -> {:error, "Gap detected: #{inspect(gap)}"}
  end
end
```

---

## Rolling Export Architecture

### Individual Clip Export

**Current**: Batch export by source_video  
**New**: Individual clip export with intelligent resource sharing

```elixir
# Modified pipeline stage
%{
  label: "approved virtual clips → rolling export",
  query: fn -> 
    ClipQueries.get_individual_clips_ready_for_export(limit: 10)
  end,
  build: fn clips -> 
    # Create individual export jobs with resource sharing hints
    Enum.map(clips, fn clip ->
      ExportWorker.new(%{
        clip_id: clip.id,
        # Hint for resource sharing optimization
        source_video_id: clip.source_video_id
      })
    end)
  end
}
```

### Enhanced Export Worker

```elixir
defmodule Heaters.Clips.Export.Worker do
  @moduledoc """
  Enhanced export worker for individual virtual clip export with resource sharing.
  
  Features:
  - Individual clip processing for rolling export
  - Intelligent gold master caching and reuse
  - Concurrent processing of clips from same source
  - Minimal resource overhead through shared downloads
  """
  
  def handle_work(%{"clip_id" => clip_id}) do
    # Process single clip with resource sharing
    case get_virtual_clip_for_export(clip_id) do
      nil -> 
        Logger.info("ExportWorker: Clip #{clip_id} already exported or not found")
        :ok
        
      clip ->
        process_individual_clip(clip)
    end
  end
  
  defp process_individual_clip(clip) do
    # Use resource manager for efficient gold master access
    case GoldMasterResourceManager.get_or_download(clip.source_video_id) do
      {:ok, gold_master_path} ->
        export_single_clip(clip, gold_master_path)
        
      {:error, reason} ->
        mark_clip_export_failed(clip, reason)
    end
  end
end
```

### Resource Sharing Manager

```elixir
defmodule Heaters.Infrastructure.GoldMasterResourceManager do
  @moduledoc """
  Manages gold master downloads and sharing across concurrent export jobs.
  
  Features:
  - Shared downloads for concurrent exports from same source
  - Automatic cleanup when no active exports
  - Resource pooling and lifecycle management
  """
  
  use GenServer
  
  def get_or_download(source_video_id) do
    GenServer.call(__MODULE__, {:get_or_download, source_video_id})
  end
  
  def release_resource(source_video_id) do
    GenServer.cast(__MODULE__, {:release, source_video_id})
  end
  
  # Implementation handles concurrent access and cleanup
end
```

---

## WebCodecs Video Player Architecture

### Technical Specifications

**Video Codecs & Quality**:
- **Gold Master**: Lossless FFV1 codec in MKV container → GLACIER storage (cost-optimized)
- **Review Proxy**: All-I-frame H.264 → STANDARD storage (fast access)
- **Final Clips**: H.264 delivery-optimized MP4s

**WebCodecs Implementation**:
```javascript
// assets/js/webcodecs-player.js
export class WebCodecsPlayer {
  constructor(sourceVideoUrl, cutPoints, keyframeOffsets) {
    this.sourceVideoUrl = sourceVideoUrl;
    this.cutPoints = cutPoints; // {start_frame: X, end_frame: Y}
    this.keyframeOffsets = keyframeOffsets;
    this.decoder = null;
    this.frameCache = new Map();
  }
  
  async seekToFrame(frameNumber) {
    // Use WebCodecs VideoDecoder for efficient frame seeking
    // Compute byte ranges on-the-fly from keyframe_offsets
    // Cache decoded frames for smooth playback
  }
  
  async initializeDecoder() {
    // Initialize WebCodecs VideoDecoder with proxy video stream
    // Configure for I-frame only H.264 decoding
  }
  
  // Compute byte ranges dynamically from keyframe offsets
  // No need to persist proxy_byte_ranges in database
  computeByteRange(startFrame, endFrame) {
    // Calculate based on keyframe_offsets and I-frame structure
  }
}
```

### Phoenix LiveView Components

```elixir
# lib/heaters_web/components/webcodecs_player.ex
defmodule HeatersWeb.WebCodecsPlayer do
  # Replace sprite_player component entirely
  # Serves WebCodecs player with source proxy URL and cut points
  # Automatic fallback to traditional video player
  
  def webcodecs_player(assigns) do
    clip = assigns.clip
    source_video = clip.source_video
    
    meta = %{
      "proxyUrl" => cdn_url(source_video.proxy_filepath),
      "cutPoints" => clip.cut_points,
      "keyframeOffsets" => source_video.keyframe_offsets,
      "totalFrames" => calculate_cut_point_frames(clip.cut_points),
      "fps" => source_video.fps || 30,
      # Include fallback video URL for older browsers
      "fallbackVideoUrl" => cdn_url(source_video.proxy_filepath)
    }
    
    ~H"""
    <div id={"player-#{@clip.id}"} 
         phx-hook="WebCodecsPlayer" 
         data-player={Jason.encode!(meta)}>
      <!-- Fallback video element for older browsers -->
      <video style="display: none;" preload="metadata">
        <source src={meta["proxyUrl"]} type="video/mp4">
      </video>
    </div>
    """
  end
end
```

### JavaScript Hook Integration

```javascript
// assets/js/app.js
let Hooks = {
  ReviewHotkeys,
  WebCodecsPlayer: WebCodecsPlayerController, // Replace SpritePlayer
  CutPointManager: CutPointManager, // New hook for cut point operations
  HoverPlay, // Update for virtual clips
}

// assets/js/webcodecs-player-controller.js  
export const WebCodecsPlayerController = {
  mounted() {
    // Automatic WebCodecs detection and fallback
    if (window.VideoDecoder && window.VideoFrame) {
      this.initWebCodecsPlayer();
    } else {
      this.initFallbackVideoPlayer();
    }
  },
  
  initWebCodecsPlayer() {
    // Use WebCodecs for frame-accurate seeking
  },
  
  initFallbackVideoPlayer() {
    // Use traditional video element for older browsers
    // Graceful degradation with basic video controls
  }
}
```

**Browser Support & Fallback**:
- **WebCodecs**: Chrome 94+, Firefox 103+, Safari 16.4+
- **Graceful Fallback**: Traditional video player for older browsers
- **Progressive Enhancement**: Automatic detection and fallback

---

## S3 Storage & CDN Architecture

### Storage Directory Structure

```
s3://bucket/
├── gold_masters/          # Lossless archival (MKV + FFV1) → GLACIER
│   └── video_123_master.mkv
├── review_proxies/        # All-I-frame proxies (H.264) → STANDARD
│   └── video_123_proxy.mp4
├── final_clips/           # Exported approved clips → STANDARD
│   ├── video_123_clip_001.mp4
│   └── video_123_clip_002.mp4
└── metadata/              # Keyframe indexes, scene cache → STANDARD
    ├── video_123_keyframes.json
    └── video_123_scenes.json
```

### Enhanced S3 Adapters

```elixir
# lib/heaters/infrastructure/adapters/s3_adapter.ex
defmodule Heaters.Infrastructure.Adapters.S3Adapter do
  # Add support for range requests for efficient proxy streaming
  def stream_range(s3_key, start_byte, end_byte) do
    # HTTP Range requests for WebCodecs byte-range fetching
  end
  
  # Add CDN URL generation for proxy files
  def proxy_cdn_url(proxy_s3_key) do
    # Optimized CDN serving for video streaming
  end
  
  # Storage class optimization
  def upload_with_storage_class(s3_key, file_path, storage_class) do
    # Upload with appropriate storage class (GLACIER, STANDARD)
  end
end
```

---

## Python Task Implementations

### Enhanced Preprocessing Task

```python
# py/tasks/preprocessing.py
def run_preprocessing(source_video_path, temp_dir, **kwargs):
    """
    Create gold master and review proxy from source video
    
    Returns:
    {
        "status": "success",
        "gold_master_path": "path/to/lossless.mkv",
        "review_proxy_path": "path/to/proxy.mp4", 
        "keyframe_offsets": [0, 150, 300, ...],
        "metadata": {...}
    }
    """
    # 1. Create lossless archival master (MKV + FFV1)
    # 2. Create all-I-frame proxy (H.264, optimized for seeking)
    # 3. Extract keyframe offsets for efficient WebCodecs seeking
```

### Updated Scene Detection Task

```python
# py/tasks/detect_scenes.py  
def run_scene_detection(proxy_video_path, **kwargs):
    """
    Detect scenes but return cut points only (no file creation)
    
    Returns:
    {
        "status": "success",
        "cut_points": [
            {"start_frame": 0, "end_frame": 150, "start_time": 0.0, "end_time": 5.0},
            {"start_frame": 150, "end_frame": 300, "start_time": 5.0, "end_time": 10.0}
        ],
        "metadata": {...}
    }
    """
    # Use existing OpenCV scene detection but don't encode clips
```

### Enhanced Export Task

```python
# py/tasks/export_clips.py
def run_clip_export(gold_master_path, cut_points_list, output_dir, **kwargs):
    """
    Export final clips from gold master using virtual cut points
    
    Args:
        cut_points_list: List of approved virtual clip cut points
        
    Returns:
    {
        "status": "success", 
        "exported_clips": [
            {"clip_id": 123, "output_path": "clip_001.mp4", "duration": 5.2},
            ...
        ]
    }
    """
    # Single encoding pass from archival master
    # Use FFmpeg copy operations where possible
```

---

## Environment Configuration

### Required Environment Variables

#### S3 Configuration
```bash
# Core S3 settings
S3_BUCKET_NAME=your-video-bucket
S3_DEV_BUCKET_NAME=your-dev-bucket      # Optional: dev-specific bucket
S3_PROD_BUCKET_NAME=your-prod-bucket    # Optional: prod-specific bucket

# Storage class optimization  
GOLD_MASTER_STORAGE_CLASS=GLACIER       # Default: GLACIER (cost-optimized)
PROXY_STORAGE_CLASS=STANDARD             # Default: STANDARD (fast access)
```

#### CDN Configuration
```bash
# WebCodecs streaming support
PROXY_CDN_DOMAIN=cdn.yourdomain.com      # CDN with range request support
CLOUDFRONT_DEV_DOMAIN=dev.cdn.yourdomain.com   # Fallback for dev
CLOUDFRONT_PROD_DOMAIN=prod.cdn.yourdomain.com # Fallback for prod
```

#### Feature Flags
```bash
# WebCodecs support toggle
WEBCODECS_ENABLED=true                   # Default: true

# Pipeline behavior
APP_ENV=development                      # or "production"
```

#### Python Environment
```bash
# Python execution (for Render/Docker)
PYTHON_EXECUTABLE=/opt/venv/bin/python3  # Path to Python in container
PYTHON_WORKING_DIR=/app                  # Working directory for Python tasks
```

### CDN Requirements

Your CDN (CloudFront/etc.) must support:
- **HTTP Range Requests** for WebCodecs byte-range fetching  
- **CORS headers** for cross-origin video access
- **Cache-Control** headers for optimal proxy video caching

### Application Configuration

```elixir
# config/runtime.exs
config :heaters,
  # Add WebCodecs support flags
  webcodecs_enabled: true,
  proxy_cdn_domain: System.get_env("PROXY_CDN_DOMAIN"),
  gold_master_storage_class: "GLACIER", # Cold storage for masters
  proxy_storage_class: "STANDARD"       # Hot storage for proxies
```

---

## Enhanced Review Interface

### Pure Cut Point Review

**Remove**: All sprite-based and merge/split UI  
**Replace**: Pure cut point manipulation interface

```elixir
# lib/heaters_web/live/review_live.ex
defmodule HeatersWeb.ReviewLive do
  # Remove all legacy merge/split event handlers
  # Replace with pure cut point operations
  
  def handle_event("add_cut_point", %{"frame" => frame_num}, socket) do
    case Clips.VirtualClips.add_cut_point(socket.assigns.source_video_id, frame_num, socket.assigns.user_id) do
      {:ok, _new_clips} ->
        # Refresh review queue and advance
        {:noreply, advance_to_next_clip(socket)}
        
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to add cut: #{reason}")}
    end
  end
  
  def handle_event("remove_cut_point", %{"frame" => frame_num}, socket) do
    case Clips.VirtualClips.remove_cut_point(socket.assigns.source_video_id, frame_num, socket.assigns.user_id) do
      {:ok, _merged_clip} ->
        {:noreply, advance_to_next_clip(socket)}
        
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove cut: #{reason}")}
    end
  end
  
  def handle_event("move_cut_point", %{"old_frame" => old_frame, "new_frame" => new_frame}, socket) do
    case Clips.VirtualClips.move_cut_point(socket.assigns.source_video_id, old_frame, new_frame, socket.assigns.user_id) do
      {:ok, _updated_clips} ->
        {:noreply, refresh_current_clip(socket)}
        
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to move cut: #{reason}")}
    end
  end
end
```

### WebCodecs Cut Point Interface

```javascript
// assets/js/cut-point-manager.js
export class CutPointManager {
  constructor(sourceVideoId, allCutPoints, currentClipCutPoints) {
    this.sourceVideoId = sourceVideoId;
    this.allCutPoints = allCutPoints;        // All cut points for this source video
    this.currentClipCutPoints = currentClipCutPoints;  // Current clip boundaries
  }
  
  // Add cut point within current clip
  addCutPoint(frameNumber) {
    // Validate frame is within current clip
    if (this.isFrameInCurrentClip(frameNumber)) {
      this.pushEvent("add_cut_point", {frame: frameNumber});
    }
  }
  
  // Remove cut point at clip boundary
  removeCutPoint(frameNumber) {
    // Validate frame is at clip boundary
    if (this.isFrameAtClipBoundary(frameNumber)) {
      this.pushEvent("remove_cut_point", {frame: frameNumber});
    }
  }
  
  // Move cut point at clip boundary
  moveCutPoint(oldFrame, newFrame) {
    if (this.isFrameAtClipBoundary(oldFrame)) {
      this.pushEvent("move_cut_point", {old_frame: oldFrame, new_frame: newFrame});
    }
  }
  
  // Visual feedback for valid cut point operations
  highlightValidCutPoints() {
    // Show where cuts can be added/removed/moved
  }
}
```

---

## Database Schema Enhancements

### Enhanced Virtual Clips

```sql
-- Add MECE validation support
ALTER TABLE clips ADD COLUMN source_video_order INTEGER;
ALTER TABLE clips ADD COLUMN cut_point_version INTEGER DEFAULT 1;

-- Add user tracking for cut point operations  
ALTER TABLE clips ADD COLUMN created_by_user_id INTEGER;
ALTER TABLE clips ADD COLUMN last_modified_by_user_id INTEGER;

-- Enhanced indexing for MECE operations
CREATE INDEX idx_clips_source_video_mece 
  ON clips(source_video_id, is_virtual, source_video_order) 
  WHERE is_virtual = true;

-- Add constraint to ensure proper ordering
ALTER TABLE clips ADD CONSTRAINT clips_mece_ordering 
  CHECK (
    (is_virtual = false) OR 
    (is_virtual = true AND source_video_order IS NOT NULL)
  );
```

### Cut Point Audit Trail

```sql
-- New table for cut point operation history
CREATE TABLE cut_point_operations (
  id SERIAL PRIMARY KEY,
  source_video_id INTEGER NOT NULL REFERENCES source_videos(id),
  operation_type VARCHAR(20) NOT NULL, -- 'add', 'remove', 'move'
  frame_number INTEGER NOT NULL,
  old_frame_number INTEGER, -- For move operations
  user_id INTEGER NOT NULL,
  affected_clip_ids INTEGER[], -- Array of clip IDs affected
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  metadata JSONB
);

CREATE INDEX idx_cut_point_ops_source_video 
  ON cut_point_operations(source_video_id, created_at DESC);
```

---

## Legacy Code Removal Plan

### Backend Modules to Remove Entirely

```
lib/heaters/clips/edits/
├── merge.ex                    # Remove entirely
├── merge/                      # Remove entirely
│   ├── calculations.ex
│   ├── file_naming.ex
│   ├── validation.ex
│   └── worker.ex
├── split.ex                    # Remove entirely
└── split/                      # Remove entirely
    ├── calculations.ex
    ├── file_naming.ex
    ├── validation.ex
    └── worker.ex

lib/heaters/clips/artifacts/
├── sprite.ex                   # Remove entirely
└── sprite/                     # Remove entirely
    ├── calculations.ex
    ├── file_naming.ex
    ├── validation.ex
    ├── video_metadata.ex
    └── worker.ex

lib/heaters/videos/splice/
├── splice.ex                   # Remove entirely
├── filepaths.ex
├── state_manager.ex
└── worker.ex
```

### Frontend Components to Remove

```
lib/heaters_web/components/
└── sprite_player.ex            # Remove entirely

assets/js/
├── sprite-player.js            # Remove entirely
├── sprite-seeker.js            # Remove entirely
└── hover-play.js               # Update to remove sprite logic
```

### Database Cleanup

```sql
-- Remove sprite artifact types entirely
DELETE FROM clip_artifacts WHERE artifact_type = 'sprite_sheet';

-- Remove legacy ingest states
-- Update or migrate clips in these states before removal:
-- 'splicing', 'splicing_failed', 'spliced'
-- 'generating_sprite', 'sprite_failed'

-- Remove legacy columns after migration
ALTER TABLE source_videos DROP COLUMN IF EXISTS needs_splicing;
```

### Pipeline Configuration Cleanup

```elixir
# Remove from PipelineConfig.stages():
# - splice stage
# - sprite generation stage  
# - all merge/split worker stages

# Keep only:
# - download → preprocess → detect_scenes → export → keyframes → embeddings
```

---

## Implementation Progress

### ✅ Phase 4: Legacy Code Removal (COMPLETED)
**Status**: **Complete** - Executed ahead of schedule for clean slate approach

**Completed Tasks**:
- [x] **Removed all merge/split/splice/sprite modules** (~42 files deleted)
  - All `lib/heaters/clips/edits/merge*` modules removed
  - All `lib/heaters/clips/edits/split*` modules removed  
  - All `lib/heaters/videos/splice*` modules removed
  - All `lib/heaters/clips/artifacts/sprite*` modules removed
- [x] **Frontend component cleanup**
  - `lib/heaters_web/components/sprite_player.ex` removed
  - `assets/js/sprite-player.js` and `assets/js/split-manager.js` removed
  - Review templates updated for WebCodecs-only approach
- [x] **Core file cleanup**
  - Pipeline configuration updated for virtual clips workflow
  - Clips contexts cleaned of legacy delegations
  - Review module simplified to virtual-only operations
  - **Directory structure flattened** - Removed `operations/` layer from both `clips/` and `videos/` contexts
- [x] **Database cleanup migration created**
  - Migration `20250724024744_remove_legacy_states_and_references.exs` created
  - Removes sprite artifacts and legacy states
  - Updates legacy clip states to `pending_review`
- [x] **Test cleanup** 
  - All test directories for legacy functionality removed
  - Legacy test files deleted
- [x] **Dialyzer warnings resolved**
  - All legacy-related compilation warnings eliminated
  - Type safety maintained throughout codebase

**Key Achievement**: **Clean slate successfully achieved** - codebase is free of all legacy merge/split/splice/sprite concepts and uses clean, flattened directory structure.

---

## Implementation Phases (Remaining)

### ✅ Phase 1: Enhanced VirtualClips Module (COMPLETED)
**Status**: **Complete** - All core cut point operations and MECE validation implemented

**Completed Tasks**:
- [x] **Implement add/remove/move cut point operations**
  - `add_cut_point/3` - Splits virtual clip at specified frame with transaction safety
  - `remove_cut_point/3` - Merges adjacent virtual clips maintaining MECE properties
  - `move_cut_point/4` - Adjusts cut point boundaries between adjacent clips
  - All operations archive original clips and create new ones atomically
- [x] **Add MECE validation functions**
  - `validate_mece_for_source_video/1` - Ensures no gaps, overlaps, or coverage holes
  - `get_cut_points_for_source_video/1` - Returns sorted list of all cut points
  - `ensure_complete_coverage/2` - Validates full source video coverage
  - Comprehensive overlap and gap detection algorithms
- [x] **Create cut point audit trail**
  - Complete audit logging for all cut point operations (add/remove/move)
  - `CutPointOperation` schema with operation metadata tracking
  - User ID tracking and affected clip IDs for full traceability
- [x] **Update database schema for MECE operations**
  - Migration `20250724025831_create_cut_point_operations_table.exs` - Audit trail table
  - Migration `20250724025848_enhance_clips_for_mece_operations.exs` - Enhanced clips table
  - Added `source_video_order`, `cut_point_version`, user tracking fields
  - MECE constraint ensures proper ordering for virtual clips
- [x] **Comprehensive test suite**
  - 19 test cases covering all operations and edge cases
  - Factory methods for creating test virtual clips
  - Full validation of MECE properties, error conditions, and audit trail
  - Coverage includes boundary validation, transaction rollbacks, and idempotency

**Key Achievements**:
- **Mathematical Soundness**: All cut point operations maintain MECE properties algorithmically
- **Transaction Safety**: All operations use database transactions with proper rollback handling
- **Audit Compliance**: Complete operation history with user tracking and metadata
- **Test Coverage**: Comprehensive test suite validates all functionality and edge cases
- **Type Safety**: Full Dialyzer compatibility with proper type specifications

**Files Modified/Created**:
- Enhanced: `lib/heaters/clips/virtual_clips.ex` (+400 lines)
- Enhanced: `lib/heaters/clips/clip.ex` (added MECE fields)
- Created: `test/heaters/clips/virtual_clips_test.exs` (comprehensive test suite)
- Enhanced: `test/support/data_case.ex` (added virtual_clip factory)
- Created: Database migrations for audit trail and MECE operations

### Phase 2: Rolling Export System (1-2 weeks)  
- [ ] Individual clip export worker enhancement
- [ ] Gold master resource sharing manager
- [ ] Update pipeline configuration for rolling export
- [ ] Performance optimization

### Phase 3: Enhanced Review Interface (2 weeks)
- [ ] Cut point manipulation UI with WebCodecs
- [ ] Implement WebCodecs player with fallback
- [ ] Update LiveView event handlers for cut point operations
- [ ] User experience testing

### Phase 5: Production Deployment (1 week) 
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

## Success Metrics

### Technical Metrics
- **MECE Validation**: 100% coverage with 0 gaps/overlaps across all source videos
- **Export Latency**: < 5 minutes from approval to physical clip availability
- **Operation Speed**: < 500ms for all cut point operations
- **Resource Efficiency**: 80% reduction in temporary file usage

### User Experience Metrics  
- **Review Speed**: 50% faster clip review workflow
- **Cut Precision**: Frame-accurate cut point placement
- **Error Reduction**: 90% fewer cut point validation errors
- **User Satisfaction**: Simplified, intuitive cut point interface

---

## Technical Considerations & Performance

### Performance Expectations
- **Cut Point Operations**: < 500ms for add/remove/move operations (database-only)
- **Export Latency**: < 5 minutes from approval to physical clip availability  
- **Storage Reduction**: 80% reduction in temporary file usage (no sprites/intermediate clips)
- **Review Speed**: 50% faster workflow vs legacy merge/split operations
- **Resource Efficiency**: Shared gold master downloads reduce I/O overhead

### Quality & Codec Specifications
- **Gold Master**: FFV1 lossless codec in MKV container (archival quality)
- **Review Proxy**: All-I-frame H.264 (optimal WebCodecs seeking performance)
- **Final Clips**: H.264 MP4 delivery format (streaming optimized)
- **Keyframe Offsets**: Byte-position arrays enable frame-perfect seeking

### Browser Compatibility & Fallback
- **WebCodecs Support**: Chrome 94+, Firefox 103+, Safari 16.4+
- **Automatic Fallback**: Traditional video element for older browsers
- **Progressive Enhancement**: Graceful degradation with no functionality loss
- **CORS & CDN**: Range request support required for optimal performance

### Deployment Checklist
1. ✅ **Database migrations applied**: Enhanced virtual clips schema
   - ✅ Legacy cleanup migration: `20250724024744_remove_legacy_states_and_references.exs`
   - ✅ Audit trail migration: `20250724025831_create_cut_point_operations_table.exs`
   - ✅ MECE operations migration: `20250724025848_enhance_clips_for_mece_operations.exs`
2. ⏳ **Environment variables set**: S3, CDN, WebCodecs configuration  
3. ⏳ **CDN configured**: Range requests enabled for proxy video streaming
4. ⏳ **Python dependencies**: FFmpeg, OpenCV, boto3 available in production
5. ⏳ **Oban queues**: New export workers included in queue configuration
6. ⏳ **Monitoring**: Alerts for cut point operation failures and performance issues

---

This enhanced virtual clips architecture eliminates legacy complexity while providing robust cut point management and efficient rolling export. The clean slate approach ensures maintainable, predictable behavior for long-term scalability.