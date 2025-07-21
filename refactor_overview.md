# Video Processing Pipeline – Universal Proxy Architecture Refactor

## Goal

Transition from **eager clip encoding + sprite-sheet review** to a **single-proxy, virtual-clip workflow**:

* One universal ingest path for both web-scraped full shows _and_ raw user-uploaded clips
* Reviewers work on *virtual* cut points against the source proxy; no re-encoding during review
* After all clips are approved, encode once from the archival master
* Eliminate sprite sheet dependency with WebCodecs-based frame seeking

---

## Current System Analysis

**Current Workflow Issues:**
- Every detected scene becomes an encoded clip file immediately (heavy I/O)
- Sprite sheets required for frame navigation (additional encoding step)
- Merge/split actions trigger re-encoding (slow feedback loop)
- Different paths for web-scraped vs user-uploaded content
- Storage overhead: source video + all individual clips + sprite sheets

**Current Architecture Strengths to Preserve:**
- Functional domain modeling with "I/O at the edges"
- Robust state management and idempotency patterns
- Oban-based pipeline with WorkerBehavior abstraction
- Declarative pipeline configuration via PipelineConfig
- Hybrid Python/Elixir processing for optimal performance

---

## New Pipeline Architecture

| Stage | Current | New | Key Changes |
|-------|---------|-----|-------------|
| **1. Universal Ingest** | Same | Same | No change - works for both user uploads and web-scraped content |
| **2. Preprocessing** | Downloads to temp → uploads clips | **Creates gold master + review proxy only** | **No individual clips created** |
| **3. Scene Detection** | Creates clip records + files | **Creates virtual clip records (cut points only)** | **Database records only, no file encoding** |
| **4. Review UI** | Sprite sheet navigation | **WebCodecs frame seeking on review proxy** | **Eliminates sprite generation entirely** |
| **5. Virtual Clip Management** | Individual clip files | **JSON cut points + proxy ranges** | **Much faster merge/split operations** |
| **6. Final Export** | Stream individual clips | **One-shot export from gold master** | **Single encoding pass with optimal quality** |

---

## Implementation Plan

### Phase 1: Database Schema Changes

**1.1 Migrate `source_videos` table**
```sql
-- Add new columns for proxy architecture
ALTER TABLE source_videos ADD COLUMN needs_splicing BOOLEAN DEFAULT true;
ALTER TABLE source_videos ADD COLUMN proxy_filepath TEXT;
ALTER TABLE source_videos ADD COLUMN keyframe_offsets JSONB;
ALTER TABLE source_videos ADD COLUMN gold_master_filepath TEXT;

-- Update indexes
CREATE INDEX idx_source_videos_needs_splicing ON source_videos(needs_splicing) WHERE needs_splicing = true;
CREATE INDEX idx_source_videos_proxy_filepath ON source_videos(proxy_filepath) WHERE proxy_filepath IS NOT NULL;
```

**1.2 Update `clips` table for virtual clips**
```sql
-- Remove physical file requirement, add virtual clip metadata  
ALTER TABLE clips ALTER COLUMN clip_filepath DROP NOT NULL;
ALTER TABLE clips ADD COLUMN is_virtual BOOLEAN DEFAULT false;
ALTER TABLE clips ADD COLUMN cut_points JSONB; -- {start_frame: X, end_frame: Y, start_time: X.X, end_time: Y.Y}

-- New indexes for virtual clip queries
CREATE INDEX idx_clips_virtual ON clips(source_video_id, is_virtual) WHERE is_virtual = true;
CREATE INDEX idx_clips_cut_points ON clips USING GIN(cut_points) WHERE is_virtual = true;

-- Constraint: clip_filepath must be present when is_virtual = false (after export)
ALTER TABLE clips ADD CONSTRAINT clips_filepath_required_when_physical 
  CHECK (is_virtual = true OR clip_filepath IS NOT NULL);
```

**1.3 Update `clip_artifacts` for proxy architecture**
```sql
-- Eliminate sprite_sheet requirement, add keyframe artifacts
-- (sprite sheets will no longer be created)
-- keyframe artifacts will reference the source proxy, not individual clips
```

### Phase 2: Backend Business Logic Changes

**2.1 Update Pipeline Configuration**
```elixir
# lib/heaters/infrastructure/orchestration/pipeline_config.ex
def stages do
  [
    # Stage 1 & 2: No changes to ingest/download
    %{
      label: "videos needing ingest → download",
      query: fn -> VideoQueries.get_videos_needing_ingest() end,
      build: fn video -> IngestWorker.new(%{source_video_id: video.id}) end
    },
    
    # Stage 3: NEW - Universal preprocessing (replaces current splice)
    %{
      label: "videos needing preprocessing → proxy generation",
      query: fn -> VideoQueries.get_videos_needing_preprocessing() end,
      build: fn video -> ProxyWorker.new(%{source_video_id: video.id}) end
    },
    
    # Stage 4: NEW - Scene detection for virtual clips (replaces current splice)
    %{
      label: "videos needing scene detection → virtual clips",
      query: fn -> VideoQueries.get_videos_needing_scene_detection() end,
      build: fn video -> SceneDetectionWorker.new(%{source_video_id: video.id}) end
    },
    
    # Stage 5: REMOVE sprite generation entirely
    # (no more clip-level sprite generation)
    
    # Stage 6: Update keyframe generation for source-level
    %{
      label: "videos needing keyframes → source keyframes",
      query: fn -> VideoQueries.get_videos_needing_keyframes() end,
      build: fn video -> SourceKeyframeWorker.new(%{source_video_id: video.id}) end
    },
    
    # Stage 7-8: Review and export stages (updated for virtual clips)
    # ... (review happens on virtual clips)
    
    # Stage 9: NEW - Final export stage
    %{
      label: "approved virtual clips → final encoding",
      query: fn -> ClipQueries.get_virtual_clips_ready_for_export() end,
      build: fn clips -> ExportWorker.new(%{clip_group_id: clips}) end
    }
  ]
end
```

**2.2 New Worker Modules with Idempotency Patterns**
```elixir
# lib/heaters/videos/operations/preprocessing/worker.ex
defmodule Heaters.Videos.Operations.Preprocessing.Worker do
  # Creates:
  # 1. Gold master (lossless MKV + FFV1) → cold storage
  # 2. Review proxy (all-intra H.264 I-frame only) → hot storage  
  # 3. Basic keyframe index for efficient seeking
  #
  # IDEMPOTENCY: Skip if proxy_filepath IS NOT NULL
  # DONE FLAG: proxy_filepath column populated
end

# lib/heaters/videos/operations/scene_detection/worker.ex
defmodule Heaters.Videos.Operations.SceneDetection.Worker do
  # Uses existing Python scene detection but creates virtual clips
  # No file encoding - just database records with cut points
  #
  # IDEMPOTENCY: Skip if needs_splicing = false OR virtual clips exist for this source_video
  # DONE FLAG: needs_splicing = false AND virtual clips created
end

# lib/heaters/clips/operations/export/worker.ex  
defmodule Heaters.Clips.Operations.Export.Worker do
  # Final export: slices gold master using virtual clip cut points
  # Encodes once from archival master for optimal quality
  # Transitions clips from virtual to physical (fills clip_filepath)
  #
  # IDEMPOTENCY: Skip if is_virtual = false (clip already exported)
  # DONE FLAG: is_virtual = false AND clip_filepath IS NOT NULL
end
```

**2.3 Update Review Module**
```elixir
# lib/heaters/clips/review.ex
defmodule Heaters.Clips.Review do
  # Update merge/split operations to work with virtual clips
  # Much faster - just updates JSON cut points instead of re-encoding
  
  def request_merge_and_fetch_next(%Clip{is_virtual: true} = prev, %Clip{is_virtual: true} = curr) do
    # Combine cut points in database
    # No file operations needed - instant feedback
  end
  
  def request_split_and_fetch_next(%Clip{is_virtual: true} = clip, frame_num) do
    # Split cut points in database  
    # No file operations needed - instant feedback
  end
end
```

**2.4 Update Queries**
```elixir
# lib/heaters/videos/queries.ex
def get_videos_needing_preprocessing() do
  # IDEMPOTENCY: videos in "downloaded" state without proxy_filepath
  from(s in SourceVideo, 
    where: s.ingest_state == "downloaded" and is_nil(s.proxy_filepath))
  |> Repo.all()
end

def get_videos_needing_scene_detection() do  
  # IDEMPOTENCY: videos with proxy but needs_splicing = true
  from(s in SourceVideo,
    where: not is_nil(s.proxy_filepath) and s.needs_splicing == true)
  |> Repo.all()
end

# lib/heaters/clips/queries.ex
def get_virtual_clips_ready_for_export() do
  # IDEMPOTENCY: virtual clips in "review_approved" state
  from(c in Clip,
    where: c.is_virtual == true and c.ingest_state == "review_approved")
  |> Repo.all()
end
```

### Phase 3: Frontend Overhaul

**3.1 Replace Sprite Player with WebCodecs Player**
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

**3.2 Update LiveView Components with Automatic Fallback**
```elixir
# lib/heaters_web/components/proxy_player.ex
defmodule HeatersWeb.ProxyPlayer do
  # Replace sprite_player component
  # Serves WebCodecs player with source proxy URL and cut points
  # Automatic fallback to traditional video player
  
  def proxy_player(assigns) do
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
         phx-hook="ProxyPlayer" 
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

**3.3 Update Review LiveView**
```elixir
# lib/heaters_web/live/review_live.ex
defmodule HeatersWeb.ReviewLive do
  # Update to work with virtual clips
  # Much faster merge/split operations (no encoding delay)
  # Remove sprite-related code
  
  def handle_event("select", %{"action" => "split", "frame" => frame_val}, socket) do
    # Instant virtual split - no worker needed
    # Update cut points in database immediately
    # Advance queue without delay
  end
end
```

**3.4 Update JavaScript Hooks with Automatic WebCodecs Detection**
```javascript
// assets/js/app.js
let Hooks = {
  ReviewHotkeys,
  ProxyPlayer: ProxyPlayerController, // Replace SpritePlayer with auto-fallback
  ProxySeeker: ProxySeeker, // New hook for frame seeking
  HoverPlay, // Update for virtual clips
}

// assets/js/proxy-player.js  
export const ProxyPlayerController = {
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

### Phase 4: Python Task Updates

**4.1 New Preprocessing Task**
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

**4.2 Update Scene Detection Task**
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

**4.3 New Export Task**
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

### Phase 5: S3 Storage Restructure

**5.1 New Directory Structure**
```
s3://bucket/
├── gold_masters/          # Lossless archival (MKV + FFV1)
│   └── video_123_master.mkv
├── review_proxies/        # All-I-frame proxies (H.264)
│   └── video_123_proxy.mp4
├── final_clips/           # Exported approved clips
│   ├── video_123_clip_001.mp4
│   └── video_123_clip_002.mp4
└── metadata/              # Keyframe indexes, scene cache
    ├── video_123_keyframes.json
    └── video_123_scenes.json
```

**5.2 Update S3 Adapters**
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
end
```

### Phase 6: Configuration & Environment

**6.1 Update Application Config**
```elixir
# config/runtime.exs
config :heaters,
  # Add WebCodecs support flags
  webcodecs_enabled: true,
  proxy_cdn_domain: System.get_env("PROXY_CDN_DOMAIN"),
  gold_master_storage_class: "GLACIER", # Cold storage for masters
  proxy_storage_class: "STANDARD"       # Hot storage for proxies
```

**6.2 Update Docker & Dependencies**
```dockerfile
# Dockerfile - Add WebCodecs polyfill support
RUN npm install --prefix assets @webcodecs/av1-decoder
```

```elixir
# mix.exs - No new Elixir dependencies needed
# WebCodecs is browser-native API
```

---

## Migration Strategy

### Phase 1: Foundation (2-3 weeks)
- Add database columns with sensible defaults  
- Implement new worker modules with idempotency patterns
- Develop WebCodecs player component with automatic fallback
- Update Python tasks for preprocessing and export

### Phase 2: Replace Pipeline (2-3 weeks)
- Switch pipeline configuration to new stages
- Update review module for virtual clip operations
- Replace sprite player with proxy player in all components
- Test end-to-end workflow with real videos

### Phase 3: Production Deployment (1 week)
- Remove old sprite generation workers and related code
- Clean up legacy database columns and constraints
- Monitor performance and optimize proxy settings

### Phase 4: Optimization (ongoing)
- Fine-tune WebCodecs performance
- Optimize proxy encoding settings
- Implement advanced caching strategies
- Monitor and improve export quality

---

## Key Benefits

1. **Universal Pipeline**: Single ingest path handles both web-scraped and user content
2. **Instant Review Actions**: Merge/split operations update database only (no encoding delay)
3. **Storage Efficiency**: Eliminates duplicate clip files and sprite sheets during review
4. **Quality Preservation**: Single encoding pass from lossless master
5. **Modern Architecture**: WebCodecs for native browser video performance
6. **Maintain Strengths**: Preserves existing functional architecture and idempotency patterns
7. **Scalable**: Reduced encoding overhead allows processing larger videos
8. **Cost Effective**: Significant reduction in storage and compute costs

---

## Technical Considerations

**WebCodecs Browser Support:**
- Chrome 94+, Firefox 103+, Safari 16.4+
- Graceful fallback to traditional video player for older browsers
- Progressive enhancement approach

**Performance Expectations:**
- 10x faster merge/split operations (database-only vs re-encoding)
- 50% reduction in storage costs (no sprite sheets, no intermediate clips)
- 70% reduction in processing time during review phase
- Single final encoding pass maintains optimal quality

**Backwards Compatibility:**
- Existing sprite-based clips continue to work during migration
- Smooth transition from virtual to physical clips via export worker
- No breaking changes to review UI/UX  
- Preserves all existing keyboard shortcuts and workflows
