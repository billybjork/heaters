# Heaters Video Processing Pipeline

## Overview

Heaters processes videos through a **cuts-based pipeline**: download → proxy generation → scene detection → cuts → human review → clip export → embedding. The system emphasizes zero re-encoding during review, optimized export performance, and production reliability.

**Core Innovation**: Cut points define video segments as data—clips are derived entities with no physical files until export. This enables instant review operations and 10x faster exports via stream copy.

## Technology Stack

- **Backend**: Elixir/Phoenix 1.8+ with LiveView 1.1
- **Database**: PostgreSQL with pgvector  
- **Media Processing**: Python (yt-dlp, FFmpeg, OpenCV, PyTorch)
- **Storage**: AWS S3 with intelligent caching
- **Frontend**: Phoenix LiveView 1.1 with colocated hooks and single-file components

## Architecture

### Cuts-Based Architecture

- **Universal Download**: Handles web-scraped and user-uploaded videos with quality-first strategy (4K/8K when available)
- **Dual-Purpose Proxy**: Single H.264 proxy serves both review and export (eliminates redundant operations)
- **Cut Points**: Scene detection creates cut boundaries; clips are segments between cuts
- **Clip Player**: On-demand MP4 generation with perfect timeline and instant playback
- **Master Archival**: High-quality H.264 stored in S3 Standard for instant access

### Core Principles

- **"I/O at the Edges"**: Pure business logic isolated from side effects; I/O only at system boundaries
- **Declarative Pipeline**: Complete workflow defined as data in `Pipeline.Config.stages()`
- **Centralized Path Management**: All S3 directory structure managed in Elixir; zero coupling between components
- **Performance-First**: Reduce S3 I/O load via temp caching; near-zero latency via direct job chaining
- **Idempotency**: All operations safe to retry with graceful error handling

## Code Organization

- **`Media`**: Domain entities (videos, clips, cuts, artifacts) and cut operations
- **`Processing`**: Automated pipeline stages (download, preprocess, scene detection, render, keyframes, embeddings)
- **`Storage`**: All storage concerns (pipeline cache, playback cache with scheduled cleanup, archive, S3 operations)
- **`Review`**: Human workflow (queue management, actions)
- **`Pipeline`**: Declarative orchestration (config, dispatcher, queries)

### Type Safety & Data Integrity

- **Ecto Enums**: All state fields (`ingest_state`, `artifact_type`, `strategy`, `generation_strategy`) use native Ecto enums
- **Database Constraints**: CHECK constraints prevent invalid enum values at the database level
- **Compile-time Validation**: Invalid enum values caught during compilation
- **Performance Indexes**: Strategic indexes on enum fields for optimized queries

## Pipeline & State Flow

```
Source Video: new → downloading → downloaded → preprocess → preprocessed → detect_scenes → cuts created

Clips: pending_review → review_approved → exporting → exported → keyframing → keyframed → embedding → embedded
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

### Clip Player (LiveView 1.1 Colocated Hooks)
- **Single-File Architecture**: JavaScript and Elixir colocated in one component file
- **Instant Playback**: Small video files vs. complex byte-range streaming
- **Perfect Timeline**: Shows exact clip duration (e.g., 3.75s) not full video length
- **Stream Copy**: Zero re-encoding ensures faster generation with zero quality loss
- **Universal Compatibility**: Works offline, all browsers, mobile optimized
- **Smart Cleanup**: Scheduled maintenance with LRU eviction and disk space monitoring
- **Reactive Updates**: Phoenix LiveView reactive pattern eliminates manual refresh requirements
- **Automatic Namespacing**: Hook names prefixed with module for collision prevention

### Frontend Architecture (LiveView 1.1)
- **Colocated Hooks**: JavaScript code embedded directly in Phoenix components
- **Change Tracking**: `:key` attributes for optimized list rendering performance
- **Debug Attributes**: Enhanced development experience with `data-phx-loc` annotations
- **LazyHTML**: Modern CSS selector support (`:is()`, `:has()`, etc.) in tests
- **Single-File Components**: Eliminates separate JavaScript files for better maintainability

### Production Reliability
- **Resumable Processing**: All stages support automatic resume after interruptions
- **Idempotent Workers**: Prevent duplicate work and handle retries gracefully
- **Race Condition Prevention**: Strategic state updates prevent Dispatcher timing conflicts
- **Centralized Error Handling**: Consistent recovery and audit trails

## Configuration

### Media Processing
- **FFmpeg**: All encoding profiles centralized in `Processing.Render.FFmpegConfig`
- **yt-dlp**: Quality-first download strategy in `Processing.Download.YtDlpConfig` with validation
- **S3 Path Management**: All S3 directory structure centralized in `Storage.S3Paths` module
- **"Dumb Python"**: Python tasks receive complete configuration and S3 paths from Elixir
- **Temp Clip Audio**: FFmpeg `-an` flag removes audio streams to prevent browser decode issues
- **Stream Copy Optimization**: Video stream copy (`-c:v copy`) with web optimization (`+faststart`)

⚠️ **CRITICAL**: All configuration centralized (download, encoding, S3 paths) with built-in validation to prevent quality-reducing mistakes (4K→360p) and path inconsistencies. Review module documentation before modifying.

### Development Environment
- **LiveView 1.1**: Phoenix 1.8+ with colocated hooks compilation support
- **ESBuild Configuration**: Updated for colocated hooks with `--alias:@=.` and NODE_PATH
- **Debug Features**: `debug_attributes: true` for enhanced development annotations
- **Python Integration**: Requires `DEV_DATABASE_URL` and `DEV_S3_BUCKET_NAME` environment variables
- **Dialyzer**: Zero warnings in configured environments; suppressions handle unconfigured PyRunner dependencies
- **Type Safety**: Full Dialyzer coverage with documented suppressions for external system interfaces
- **Enum Safety**: All state fields use Ecto enums with database constraints for compile-time and runtime validation

### Review Actions
- **Instant Execution**: `approve`, `skip`, `archive`, `group` execute immediately
- **Cut Operations**: `add_cut`, `remove_cut`, `move_cut` with declarative validation
- **Simple Undo**: UI-level undo (Ctrl+Z) for most recent action only

### Maintenance & Monitoring
- **Scheduled Cleanup**: Playback cache maintenance every 4 hours via Oban cron
- **Cache Size Limits**: Configurable limits (default: 1GB) with LRU eviction strategy
- **Disk Space Monitoring**: Alerts when free space drops below threshold (default: 500MB)
- **Startup Cleanup**: Automatic removal of orphaned temp files on application start
- **Comprehensive Logging**: Cache statistics, utilization metrics, and cleanup operations

## Troubleshooting

### Common Issues

**Video Playback Problems**
- Check browser console for decode errors and JavaScript exceptions
- Verify source video proxy files are available in S3
- Review FFmpeg command logs for encoding issues

**Performance Issues**
- Monitor Oban job queues for backlog or failed jobs
- Check database query performance for large clip sets
- Verify S3 connectivity and CloudFront cache behavior

**Background Job Issues**
- Review Oban worker logs for failed attempts
- Check for duplicate job execution patterns
- Verify PubSub message delivery for LiveView updates

See module documentation and inline comments for specific implementation details and solutions.

## Key Benefits

1. **Zero Re-encoding During Review**: Cut-based clips enable instant operations
2. **Superior Export Quality**: Stream copy from high-quality proxy (CRF 20)
3. **Optimized I/O**: 78% S3 reduction + direct access via presigned URLs
4. **FLAME Ready**: Near-zero pipeline latency via direct job chaining
5. **Universal Workflow**: Handles all ingest types with smart optimization
6. **Production Reliable**: Resumable, idempotent, robust with graceful fallbacks
7. **Maintainable**: Declarative configuration, modular design, centralized S3 path management
8. **Type Safe**: Ecto enums with database constraints ensure data integrity and prevent invalid states
9. **Self-Managing**: Automated cache maintenance with size limits, LRU eviction, and disk space monitoring
10. **Reactive Interface**: LiveView reactive patterns eliminate manual refresh requirements
11. **Single-File Components**: LiveView 1.1 colocated hooks eliminate JavaScript file sprawl
12. **Performance Optimized**: Change tracking with `:key` attributes reduces unnecessary re-renders