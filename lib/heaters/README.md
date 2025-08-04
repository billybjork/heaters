# Heaters Video Processing Pipeline

## Overview

Heaters processes videos through a **virtual clip pipeline**: download → proxy generation → virtual clips → human review → final export → embedding. The system emphasizes zero re-encoding during review, optimized export performance, and production reliability.

**Core Innovation**: Virtual clips are database records with cut points—no physical files until final export. This enables instant review operations and 10x faster exports via stream copy.

## Technology Stack

- **Backend**: Elixir/Phoenix with LiveView
- **Database**: PostgreSQL with pgvector  
- **Media Processing**: Python (yt-dlp, FFmpeg, OpenCV, PyTorch)
- **Storage**: AWS S3 with intelligent caching
- **Frontend**: Clip player with on-demand generation

## Architecture

### Virtual Clip System

- **Universal Download**: Handles web-scraped and user-uploaded videos with quality-first strategy (4K/8K when available)
- **Dual-Purpose Proxy**: Single H.264 proxy serves both review and export (eliminates redundant operations)
- **Virtual Clips**: Database records only—no physical files until export
- **Clip Player**: On-demand MP4 generation with perfect timeline and instant playback
- **Master Archival**: Lossless FFV1/MKV stored in S3 Glacier

### Core Principles

- **"I/O at the Edges"**: Pure business logic isolated from side effects; I/O only at system boundaries
- **Declarative Pipeline**: Complete workflow defined as data in `Pipeline.Config.stages()`
- **Performance-First**: Reduce S3 I/O load via temp caching; near-zero latency via direct job chaining
- **Idempotency**: All operations safe to retry with graceful error handling

## Code Organization

- **`Media`**: Domain entities (videos, clips, artifacts) and cut point operations
- **`Processing`**: Automated pipeline stages (download, preprocess, scene detection, render, keyframes, embeddings)
- **`Storage`**: All storage concerns (pipeline cache, playback cache, archive, S3 operations)
- **`Review`**: Human workflow (queue management, actions)
- **`Pipeline`**: Declarative orchestration (config, dispatcher, queries)

## Pipeline & State Flow

```
Source Video: new → downloading → downloaded → preprocess → preprocessed → detect_scenes → virtual clips

Virtual Clips: pending_review → review_approved → exporting → exported → keyframing → keyframed → embedding → embedded
                    ↓                ↓              ↓            ↓              ↓           ↓           ↓
            review_skipped    review_archived   export_failed  (resumable)  keyframe_failed  (resumable) embedding_failed
```

**Direct Job Chaining** (FLAME optimized):
- Download → Preprocess → Scene Detection → Cache Upload
- Other stages use standard Oban scheduling

## Performance Features

### Temp Cache System
- **78% S3 Reduction**: Eliminates PUT→GET→PUT round trips between pipeline stages
- **Smart Proxy Reuse**: H.264 ≤1080p content reused directly when suitable
- **Batch Upload**: All cached files uploaded to S3 only once at pipeline completion

### Clip Player
- **Instant Playback**: Small video files vs. complex byte-range streaming
- **Perfect Timeline**: Shows exact clip duration (e.g., 3.75s) not full video length
- **Stream Copy**: Zero re-encoding ensures faster generation with zero quality loss
- **Universal Compatibility**: Works offline, all browsers, mobile optimized

### Production Reliability
- **Resumable Processing**: All stages support automatic resume after interruptions
- **Idempotent Workers**: Prevent duplicate work and handle retries gracefully
- **Centralized Error Handling**: Consistent recovery and audit trails

## Configuration

### Media Processing
- **FFmpeg**: All encoding profiles centralized in `Processing.Render.FFmpegConfig`
- **yt-dlp**: Quality-first download strategy in `Processing.Download.YtDlpConfig` with validation
- **"Dumb Python"**: Python tasks receive complete configuration from Elixir

⚠️ **CRITICAL**: All download configuration centralized with built-in validation to prevent quality-reducing mistakes (4K→360p). Review module documentation before modifying.

### Review Actions
- **Instant Execution**: `approve`, `skip`, `archive`, `group` execute immediately
- **Cut Point Operations**: `add_cut_point`, `remove_cut_point`, `move_cut_point` with audit trail
- **Simple Undo**: UI-level undo (Ctrl+Z) for most recent action only

## Key Benefits

1. **Zero Re-encoding During Review**: Virtual clips enable instant operations
2. **Superior Export Quality**: Stream copy from high-quality proxy (CRF 20)
3. **Optimized I/O**: 78% S3 reduction + direct access via presigned URLs
4. **FLAME Ready**: Near-zero pipeline latency via direct job chaining
5. **Universal Workflow**: Handles all ingest types with smart optimization
6. **Production Reliable**: Resumable, idempotent, robust with graceful fallbacks
7. **Maintainable**: Declarative configuration, modular design, centralized logic