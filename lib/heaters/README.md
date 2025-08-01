# Heaters Video Processing Pipeline

## Overview

Heaters processes videos through a **virtual clip pipeline**: download → proxy generation → virtual clips → human review → final export → embedding. The system is built on functional architecture principles, with Elixir orchestration and Python for CV/ML/media processing, emphasizing modularity, maintainability, and production reliability.

### Virtual Clip Architecture

- **Universal Download**: Handles both web-scraped and user-uploaded videos
- **Proxy Generation**: Creates lossless master (FFV1/MKV, Glacier archival) and proxy (all-I-frame H.264, dual-purpose)
- **Virtual Clips**: Database records with cut points; no physical files until final export
- **Instant Review**: Tiny-file video player with on-demand clip generation for seeking and review actions (approve, skip, archive, group, cut point ops)  
- **Optimized Export**: Stream copy from proxy for 10x performance and superior quality

**Key Benefits**: Zero re-encoding during review, optimized export performance, cost-effective storage, instant operations, universal workflow, maintainable codebase.

### Technology Stack
- **Backend**: Elixir/Phoenix with LiveView
- **Database**: PostgreSQL with pgvector
- **Scene Detection**: Python OpenCV via PyRunner
- **Keyframe Extraction**: Native Elixir FFmpeg
- **ML Processing**: Python (PyTorch, Transformers)
- **Media Processing**: Python (yt-dlp, FFmpeg)
- **Storage**: AWS S3
- **Frontend**: Tiny-file video player, native HTML5 video, modular JS, Phoenix LiveView

### Tiny-File Video Player Implementation

The video review interface uses a **tiny-file approach** that generates small MP4 files on-demand for superior user experience compared to traditional streaming methods.

**How It Works**:
- **On-Demand Generation**: When a virtual clip is accessed, FFmpeg generates a small (2-5MB) MP4 file using stream copy (no re-encoding)
- **Instant Playback**: Files start playing immediately with correct timeline duration showing only the clip length
- **Simple File Serving**: Uses standard HTTP file serving instead of complex streaming protocols
- **Perfect Timeline**: Each clip displays its actual duration (e.g., 3.75 seconds) rather than the full source video length

**Technical Implementation**:
- **Development Mode**: Files generated in `/tmp` and served via Phoenix static file serving
- **Production Mode**: Files uploaded to S3 with CloudFront caching for global distribution
- **FFmpeg Stream Copy**: No re-encoding ensures zero quality loss and 10x faster generation
- **Automatic Cleanup**: Temporary files auto-deleted after 15 minutes to manage disk space

**Key Advantages**:
- ✅ **Instant Playback**: 2-5MB files start immediately vs. waiting for byte-range chunks
- ✅ **Perfect Timeline**: Shows exact clip duration eliminating user confusion
- ✅ **Offline Development**: Works fully offline without CloudFront configuration
- ✅ **Simple Debugging**: Standard file serving vs. complex range request debugging
- ✅ **Browser Compatibility**: Works consistently across all browsers and devices
- ✅ **Mobile Optimized**: Touch controls and timeline scrubbing work perfectly

**Architecture Components**:
- **`Storage.PlaybackCache.TempClip`**: Generates temporary clips in development using local proxy files
- **`Processing.Render.Export`**: Handles production export with S3 upload and database tracking
- **`StreamingVideoPlayer`**: JavaScript component providing consistent playback experience
- **`VideoUrlHelper`**: Manages URL generation and routing between development/production modes

This approach eliminates the complexity and pain points of Media Fragments (byte-range streaming) while providing superior user experience and maintainable code.

## Architecture Principles

- **Functional Domain Modeling & "I/O at the Edges"**: All business logic is implemented as pure, testable functions, isolated from side effects. I/O operations (database, S3, FFmpeg, Python tasks) are handled only at the boundaries of the system, in orchestration or adapter modules. This separation ensures code is predictable, easy to test, and maintainable, with clear boundaries between pure logic and external effects.
- **Declarative Pipeline Configuration**: Complete workflow defined as data in `Pipeline.Config.stages()`, making it easy to see, modify, and test the entire pipeline flow without touching worker code.
- **Performance-First Optimizations**: Temp cache system eliminates 78% of S3 operations; direct job chaining eliminates dispatcher latency for FLAME environments.
- **Semantic Organization**: Clear distinction between user edits and automated artifacts
- **Direct Action Execution**: Review actions execute immediately; only simple UI-level undo (Ctrl+Z) remains
- **Centralized Configuration**: FFmpeg settings, yt-dlp options, S3 path management, and job chaining logic centralized in Elixir
- **Hybrid Processing**: Elixir for orchestration, Python for CV/ML/media
- **Robust Error Handling**: Centralized error handling and audit trails
- **Idempotency**: All operations are safe to retry

## State Flow

### Virtual Clip Pipeline

```
Source Video: new → downloading → downloaded → preprocess → preprocessed → detect_scenes → virtual clips created

Virtual Clips: pending_review → review_approved → exporting → exported → keyframing → keyframed → embedding → embedded
                    ↓                ↓              ↓            ↓              ↓           ↓           ↓
            review_skipped    review_archived   export_failed  (resumable)  keyframe_failed  (resumable) embedding_failed
```

## Performance Optimizations

### Temp Cache System
- **78% S3 Reduction**: Eliminates PUT→GET→PUT round trips between pipeline stages
- **Smart Proxy Reuse**: H.264/AAC ≤1080p content reused directly as proxy when suitable
- **Conditional Master Generation**: Skipped for lower-quality content to reduce costs
- **Pipeline Chaining**: Files cached locally through download→preprocess→detect_scenes stages
- **Intelligent Finalization**: Maps temp cache keys to S3 destinations via database queries
- **Batch Upload**: All cached files uploaded to S3 only once at pipeline completion

### Direct Job Chaining
- **Zero Dispatcher Latency**: Workers directly invoke next stage workers upon completion
- **FLAME Environment Optimized**: Reduces pipeline latency from 3 minutes to milliseconds
- **Configuration-Driven**: All chaining logic defined in `Pipeline.Config.stages()` with condition functions
- **Graceful Fallback**: Failed chaining falls back to Oban-based processing
- **Centralized Logic**: All chaining handled in `Pipeline.Config.maybe_chain_next_job()`

**Chaining Stages**:
- Download → Preprocess (when download completes successfully)
- Preprocess → Detect Scenes (when preprocessing completes and splicing is needed)
- Detect Scenes → Upload Cache (when scene detection completes)
- Other stages use standard Oban job scheduling

## Key Design Decisions

### Context-Oriented Organization

- **`Media`**: Domain entities (clips, videos, virtual clips, artifacts) with CQRS separation (queries/, commands/)
- **`Processing`**: All automated processing stages (download/, preprocess/, detect_scenes/, render/, keyframes/, embeddings/, py/)
- **`Storage`**: All storage concerns with context separation (pipeline_cache/, playback_cache/, archive/, s3.ex)
- **`Review`**: Human workflow (queue management, review actions)
- **`Database`**: Persistence layer with ports & adapters pattern
- **`Pipeline`**: Declarative orchestration configuration

### Centralized Media Processing Configuration

- **FFmpeg Configuration**: All encoding profiles and settings managed in `Processing.Render.FFmpegConfig` for consistency and maintainability
- **yt-dlp Configuration**: All download strategies, format options, and quality settings managed in `Processing.Download.YtDlpConfig` with validation
- **"Dumb Python" Architecture**: Python tasks receive complete configuration from Elixir and focus purely on execution

### Direct Action Execution

- **Simple Actions**: `approve`, `skip`, `archive`, `group` execute instantly
- **Cut Point Operations**: `add_cut_point`, `remove_cut_point`, `move_cut_point` are instant DB transactions with audit trail
- **Undo**: Only simple UI-level undo (Ctrl+Z) for the most recent action

### Modular, Maintainable Codebase

- All modules are focused and single-responsibility
- Deprecated code, legacy features, and transitional logic have been removed
- Documentation and code structure are kept in sync

### Optimized Storage Strategy

**Dual-Purpose Proxy**: Single proxy file serves both tiny-file video review and final export, eliminating redundant file operations.

**Cost-Effective Archival**: Master stored in S3 Glacier (95% storage savings) for compliance/archival only.

**Export Performance**: Stream copy from proxy achieves 10x performance improvement with superior quality (CRF 20 vs deprecated CRF 23).

**I/O Optimization**: Direct S3 access via presigned URLs eliminates proxy download bottleneck.

## Context Responsibilities

- **`Media`**: Pure domain entities (videos, clips, virtual clips, artifacts) and domain helpers
- **`Review`**: Human-driven review workflow (queues, LiveView helpers, actions)
- **`Processing`**: Automated CPU work (download → preprocess → detect_scenes → render/export → keyframes → embeddings)
- **`Storage`**: All storage concerns (temp cache, S3 adapters, archive, temp dirs, playback cache for tiny-file generation)
- **`Database`**: Database operations and persistence layer (repo port, ecto adapter)
- **`Pipeline`**: Declarative orchestration metadata & helpers (stage map, dispatcher, worker behaviour)
- **`Python Tasks`**: Focused execution of media processing, scene detection, S3 operations with configuration provided by Elixir

## Production Reliability Features

- **Resumable Processing**: All stages support automatic resume after interruptions
- **Idempotent Workers**: Prevent duplicate work and handle retries gracefully
- **Centralized Error Handling**: Consistent error recovery and logging
- **Database Schema Robustness**: Consistent datetime handling, audit trails, and constraints

## Key Benefits

1. **Zero Re-encoding During Review**: Virtual clips are DB records only; instant operations
2. **Superior Quality**: Export from high-quality proxy (CRF 20) with zero transcoding loss
3. **Optimized I/O Performance**: 78% S3 operation reduction via temp caching; direct access
4. **FLAME Environment Ready**: Near-zero pipeline latency via direct job chaining
5. **Universal Workflow**: Handles all ingest types with smart optimization detection
6. **True Virtual Clips**: Tiny MP4 files generated on-demand with exact clip content using FFmpeg stream copy
7. **Instant Review**: Each clip plays as a standalone video file with correct timeline duration
8. **Maintainable Codebase**: Declarative configuration, modular design, centralized logic
9. **Production Reliable**: Resumable, idempotent, robust with graceful fallbacks

## Media Processing Configuration

### yt-dlp Download Strategy

The system uses a **quality-first download strategy** with robust fallback mechanisms to ensure best possible video quality (including 4K/8K when available).

⚠️  **CRITICAL**: All download configuration is now centralized in `Processing.Download.YtDlpConfig` with built-in validation to prevent quality-reducing mistakes. Do not modify format strings or client configurations without reviewing the module documentation.

**Architecture**:
- **Configuration**: Complete yt-dlp setup managed in `Processing.Download.YtDlpConfig` module
- **Execution**: Python task receives configuration and focuses on execution only
- **Validation**: Built-in checks prevent configurations that reduce quality from 4K to 360p

**Key Features**:
- Three-tier fallback strategy (primary → fallback1 → fallback2)
- Playlist prevention (single video from playlist URLs)
- Quality-first format selection with automatic client optimization
- Conditional normalization for merge issue resolution
- Comprehensive timeout and error handling

**Expected Results**: ~49 available formats including 4K (2160p), 1440p, multiple 1080p options.