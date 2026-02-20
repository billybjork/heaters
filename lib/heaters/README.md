# Heaters Video Processing Pipeline

## Overview

Heaters processes videos through a **cuts-based pipeline**: download → encoding → scene detection → cuts → human review → clip export → embedding. The system emphasizes zero re-encoding during review, optimized export performance, and production reliability.

**Core Innovation**: Cut points define video segments as data—clips are derived entities with no physical files until export. This enables instant review operations and 10x faster exports via stream copy.

## Technology Stack

- **Backend**: Elixir/Phoenix 1.8+ with LiveView 1.1
- **Database**: PostgreSQL with pgvector  
- **Media Processing**: Native Elixir/FFmpeg with selective Python integration for specialized tasks
- **Storage**: AWS S3 with intelligent caching and native ExAws integration
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
- **`Processing`**: Automated pipeline stages with structured results and native Elixir implementations (download, encode, scene detection, export, keyframes, embeddings)
- **`Storage`**: All storage concerns (pipeline cache, temp cache with scheduled cleanup, archive, S3 operations)
- **`Review`**: Human workflow (queue management, actions)
- **`Pipeline`**: Declarative orchestration (config, dispatcher, queries)

### Consolidated Architecture

Recent optimizations consolidated related functionality for improved maintainability:

- **`Storage.S3.ClipUrls`**: Unified URL generation for both exported clips and virtual clips with auto-detection of optimal streaming format
- **`MediaController`**: Consolidated video submission and virtual clip streaming endpoints with consistent error handling

### Type Safety & Data Integrity

- **Ecto Enums**: All state fields (`ingest_state`, `artifact_type`, `strategy`, `generation_strategy`) use native Ecto enums
- **Structured Results**: All processing workers return enforced struct types with `@enforce_keys` for guaranteed data integrity
- **Database Constraints**: CHECK constraints prevent invalid enum values at the database level
- **Compile-time Validation**: Invalid enum values caught during compilation
- **Performance Indexes**: Strategic indexes on enum fields for optimized queries
- **Rich Observability**: Worker results include processing metrics, timing data, and structured logging for production monitoring

## Pipeline & State Flow

```
Source Video: new → downloading → downloaded → encoding → encoded → detect_scenes → cuts created

Clips: pending_review → review_approved → exporting → exported → keyframing → keyframed → embedding → embedded
           ↓                ↓              ↓            ↓              ↓           ↓           ↓
   review_skipped    review_archived   export_failed  (resumable)  keyframe_failed  (resumable) embedding_failed
                     (terminal)                                                                  (resumable)
```

**Direct Job Chaining** (FLAME optimized):
- Download → Encoding → Scene Detection → Cache Upload
- Export → Keyframes → Embeddings (post-review)
- Other stages use standard Oban scheduling

### Embedding Backfill (Defaults Enforcement)

- The pipeline includes a stage that finds embedded clips missing the configured default embedding (by `model_name` + `generation_strategy`) and enqueues jobs only for those clips.
- This keeps defaults in `Pipeline.Config` authoritative and prevents flooding the queue when defaults change.
- Embeddings are treated as derived data stored in Postgres (`pgvector`) and are upserted using a unique key on `(clip_id, model_name, generation_strategy)` to stay in sync with the underlying content.

## Performance Features

### Temp Cache System
- **78% S3 Reduction**: Eliminates PUT→GET→PUT round trips between pipeline stages
- **Smart Proxy Reuse**: H.264 ≤1080p content reused directly when suitable
- **Batch Upload**: All cached files uploaded to S3 only once at pipeline completion

#### On-demand asset retrieval & retries

- All media stages use a cache-first, S3-fallback pattern via `TempCache.get_or_download/2` to ensure dependent assets exist at execution time.
- Encode: fetches source video locally or re-downloads if missing.
- Detect Scenes: fetches proxy locally or re-downloads if missing.
- Keyframes: fetches exported clip locally or re-downloads if missing; also writes generated keyframe images into the temp cache for the next stage.
- Embeddings: consumes local keyframe image paths and will re-download keyframes on-demand if the cache has been cleared.
- This makes retries resilient even after cache eviction and preserves idempotency across stages.

### Clip Player (LiveView 1.1 Colocated Hooks)
- **Single-File Architecture**: JavaScript and Elixir colocated in one component file
- **Frame-Accurate Navigation**: Split mode with precise frame stepping using database FPS data
- **HTTP Range Support**: 206 Partial Content responses enable reliable video seeking
- **All-I H.264 Encoding**: Every frame is a keyframe for perfect seeking in review mode
- **Perfect Timeline**: Shows exact clip duration (e.g., 3.75s) not full video length
- **Unified Generation**: Uses same StreamClip abstraction as export system for consistency
- **Universal Compatibility**: Works offline, all browsers, mobile optimized
- **Smart Cleanup**: Scheduled maintenance with LRU eviction and disk space monitoring
- **Reactive Updates**: Phoenix LiveView reactive pattern eliminates manual refresh requirements
- **Intelligent Preloading**: Browser prefetch with metadata caching for instant transitions
- **Optimized Network Usage**: Request deduplication and proper event cleanup prevent performance issues

### Temp Clip Architecture

Temp clips provide instant playback of video segments using small generated files with FFmpeg stream copy (audio included) for frame-accurate navigation and split operations.

#### Key Features

- **FFmpeg Stream Copy**: Instant generation from all-I proxy files with zero re-encoding (audio preserved)
- **Background Generation**: Oban workers on `:temp_clips` queue with PubSub reactive updates to LiveView
- **Automatic Cleanup**: Scheduled LRU eviction (1GB limit), age expiry (15 min), and disk space monitoring

#### Coordinate System Design

Complex coordinate translations are handled server-side to eliminate client-side brittleness:

1. **Source Video Coordinates** — `0s` to `video.duration_seconds`; used by database, cut definitions, server-side calculations
2. **Video Element Coordinates** — `video.currentTime` uses absolute source video time for temp clips
3. **Clip UI Coordinates** — Timeline shows `0s` to `clip.duration_seconds` for display only

**Split flow**: Client sends a simple time offset; server translates to absolute frame using authoritative database FPS (see `review/actions.ex`).

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
- **Structured Observability**: Rich worker metrics with processing statistics, timing data, and operation details for comprehensive monitoring

## Configuration

### Media Processing
- **FFmpeg**: Native Elixir with encoding profiles centralized in `Processing.Support.FFmpeg.Config`
- **Unified Clip Generation**: Single abstraction (`Processing.Support.FFmpeg.StreamClip`) handles both temp and export clips
- **Frame-Perfect Encoding**: All-I H.264 with CFR encoding for reliable seeking in review interface
- **HTTP Range Requests**: MediaController serves virtual clips with 206 Partial Content support
- **Direct CloudFront Processing**: No local downloads, processes directly from CloudFront URLs with stream copy
- **Video Processing**: Native Elixir implementations for encoding, export, and S3 operations with structured result types
- **Specialized Python**: Selective integration for yt-dlp downloads, OpenCV scene detection, and ONNX Runtime embeddings
- **S3 Operations**: Native ExAws integration with progress reporting, multipart uploads, exponential backoff retry logic
- **Stream Copy Optimization**: Direct CloudFront → S3 processing with zero re-encoding for 10x performance improvement
- **Temp Cache System**: Smart file caching with LRU eviction to minimize S3 operations and improve pipeline performance

⚠️ **CRITICAL**: All configuration centralized (download, encoding, S3 paths) with built-in validation to prevent quality-reducing mistakes (4K→360p) and path inconsistencies. Review module documentation before modifying.

### Keyframe & Embedding Configuration

- Defaults for post-review stages are centralized in `Heaters.Pipeline.Config` and can be overridden via application config.
- Default keys:
  - `default_keyframe_strategy` (e.g., "multi", "midpoint")
  - `default_embedding_model` (e.g., "openai/clip-vit-base-patch32")
  - `default_embedding_generation_strategy` (e.g., "keyframe_multi_avg", "keyframe_single")

Override in `config/dev.exs` (or `prod.exs`):

```elixir
config :heaters,
  default_keyframe_strategy: "multi",
  default_embedding_model: "openai/clip-vit-base-patch32",
  default_embedding_generation_strategy: "keyframe_multi_avg"
```

- If `default_embedding_generation_strategy` is not set, a sensible default is chosen from the keyframe strategy:
  - "multi" → "keyframe_multi_avg"
  - "midpoint" → "keyframe_single"

- The pipeline stages (Export → Keyframes → Embeddings) read these defaults when building job args, so A/B or 2×2 experiments can be run by setting different values per environment.
- For per-item experimentation, you can adjust the arg builders in `Pipeline.Config` to read strategy/model from the database per clip or source video.

#### Defaults Enforcement & Idempotency

- A dedicated backfill stage ensures clips in `embedded` state also have the default embedding variant present. Only missing variants are queued.
- Idempotency for embeddings is based on the tuple `(clip_id, model_name, generation_strategy)`. Attempts to create the same variant will upsert and replace `embedding`, `embedding_dim`, and `model_version`.
- When keyframe artifacts or strategies change, re-running the embedding job updates the stored vector via upsert to maintain consistency.

### Development Environment
- **LiveView 1.1**: Phoenix 1.8+ with colocated hooks compilation support
- **ESBuild Configuration**: Updated for colocated hooks with `--alias:@=.` and NODE_PATH
- **Debug Features**: `debug_attributes: true` for enhanced development annotations
- **Python Integration**: Requires `DEV_DATABASE_URL` and `DEV_S3_BUCKET_NAME` environment variables
- **Python Dependency Management**: Uses `uv` with `py/pyproject.toml` and `py/uv.lock` (`uv sync --project py`)
- **Ops Reference**: See `docs/environment-operations.md` for minimal env vars and run commands
- **Dialyzer**: Zero warnings in configured environments; suppressions handle unconfigured PyRunner dependencies
- **Type Safety**: Full Dialyzer coverage with documented suppressions for external system interfaces
- **Enum Safety**: All state fields use Ecto enums with database constraints for compile-time and runtime validation

### Review Actions
- **Immediate Persistence**: All actions (`approve`, `skip`, `archive`, `merge`, `group`) persist to database immediately via async operations
- **Action Availability**: Smart button disabling prevents ineffective operations:
  - `merge`: Disabled when no preceding clip exists or clip starts at frame 0 (requires cut point)
  - `group`: Disabled when no preceding clip exists or clip starts at frame 0 (requires adjacent clips)
  - Actions validate clip relationships and prevent database operations that would have no effect
- **Special Action Handling**: 
  - `merge`: Uses cuts-based `remove_cut` operation to merge clips by eliminating cut points
  - `group`: Requires two-clip coordination; finds preceding clip and uses `request_group_and_fetch_next/2`
  - Single-clip actions (`approve`, `skip`, `archive`) use standard SQL state transitions
- **Cut Operations**: `add_cut`, `remove_cut`, `move_cut` with declarative validation  
- **Enhanced Undo**: Database-level reversion (Ctrl+Z) restores clips to `pending_review` state and UI navigation
- **Archive Behavior**: `review_archived` clips excluded from review queue; reappear only after undo
- **Temp File Cleanup**: Archived clip temp files cleaned automatically by temp cache maintenance

### Frame-by-Frame Navigation (Split Mode)
⚠️ **CRITICAL IMPLEMENTATION**: The frame navigation system requires specific encoding and HTTP transport:

**Essential Components**:
- **Stream Copy from All-I Proxies**: `temp_playback` profile uses stream copy from all-I proxy files for instant generation
- **Metadata Preservation**: Stream copy preserves original framerate and timing for precise navigation
- **HTTP Range Support**: `MediaController.proxy_video` returns 206 Partial Content responses for virtual clips
- **JavaScript Integration**: `ClipPlayer` hook coordinates with `ReviewHotkeys` for split mode
- **Event Handler Cleanup**: Proper cleanup prevents stale time references during transitions
- **Debounced Corrections**: 300ms cooldown with tolerance buffers prevents correction loops

**DO NOT**:
- Switch to re-encoding temp_playback (reduces performance and increases load)
- Remove Accept-Ranges or 206 response handling (causes snap-to-zero)
- Modify hook `handleEvent` registration pattern (causes LiveView conflicts)
- Remove FPS data from clip_info (breaks frame precision)
- Disable metadata caching or request deduplication (causes duplicate network requests)
- Remove event handler cleanup (causes stale time references)

**Keyboard Controls**:
- Right arrow: Enter split mode + step forward
- Left/Right arrows: Navigate frames (1/fps precision)  
- Enter: Commit split at current frame
- Escape: Exit split mode

### Maintenance & Monitoring
- **Scheduled Cleanup**: Playback cache maintenance every 4 hours (prod) / 5 min (dev) via Oban cron
- **Cache Size Limits**: Configurable limits (default: 1GB) with LRU eviction strategy
- **Disk Space Monitoring**: Alerts when free space drops below threshold (default: 500MB)
- **Startup Cleanup**: Automatic removal of orphaned pipeline cache directories (`heaters_*`) on application start (via `TempManager`; playback cache `clip_*` files are handled by the scheduled `CleanupWorker`)
- **Comprehensive Logging**: Cache statistics, utilization metrics, and cleanup operations

## Troubleshooting

### Common Issues

**Video Playback Problems**
- Check browser console for decode errors and JavaScript exceptions
- Verify source video proxy files are available in S3
- Review FFmpeg command logs for encoding issues

**Frame Navigation Problems**
- Verify 206 Partial Content responses in DevTools Network tab (not 200 OK)
- Check Accept-Ranges: bytes header is present on virtual clip requests
- Confirm `temp_playback` profile uses stream copy from all-I proxy files
- Validate FPS data is present in clip_info JSON
- Look for "handleEvent overwrites" warnings (hook conflicts)
- Check for excessive time correction messages (should see debounced corrections)
- Monitor for duplicate metadata requests (should see "Using cached metadata")
- Verify clean clip transitions without stale time references

**Performance Issues**
- Monitor Oban job queues for backlog or failed jobs
- Check database query performance for large clip sets
- Verify S3 connectivity and CloudFront cache behavior
- Check for duplicate network requests in DevTools (should see intelligent deduplication)
- Monitor clip transition speed (should be <50ms with prefetched metadata)
- Verify browser prefetch requests for upcoming clips

**Background Job Issues**
- Review Oban worker logs for failed attempts
- Check for duplicate job execution patterns
- Verify PubSub message delivery for LiveView updates

**Review Action Issues**
- Check button disabled state for actions that require preceding clips (`merge`, `group`)
- Verify database changes when actions complete (check `grouped_with_clip_id`, `ingest_state`, `reviewed_at`)
- Review `handle_group_action` and `handle_merge_action` logs for special action debugging
- Confirm UI and database state consistency for two-clip operations

See module documentation and inline comments for specific implementation details and solutions.

## Key Benefits

1. **Zero Re-encoding During Review**: Cut-based clips enable instant operations
2. **Frame-Accurate Navigation**: Precise frame stepping with database FPS and HTTP range support
3. **Unified Architecture**: Single abstraction handles both temp and export clips with consistent performance
4. **Direct CloudFront Processing**: No downloads, 10x faster generation with stream copy from CloudFront URLs
5. **Superior Export Quality**: Stream copy from high-quality proxy preserves original quality with audio
6. **Optimized I/O**: 78% S3 reduction + direct access via presigned URLs
7. **FLAME Ready**: Near-zero pipeline latency via direct job chaining
8. **Universal Workflow**: Handles all ingest types with smart optimization
9. **Production Reliable**: Resumable, idempotent, robust with graceful fallbacks
10. **Maintainable**: Declarative configuration, modular design, centralized S3 path management
11. **Type Safe**: Ecto enums with database constraints and structured worker results ensure complete data integrity
12. **Self-Managing**: Automated cache maintenance with size limits, LRU eviction, and disk space monitoring
13. **Reactive Interface**: LiveView reactive patterns eliminate manual refresh requirements
14. **Performance Optimized**: Change tracking with `:key` attributes reduces unnecessary re-renders
