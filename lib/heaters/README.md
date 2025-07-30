# Heaters Video Processing Pipeline

## Overview

Heaters processes videos through a **virtual clip pipeline**: download → proxy generation → virtual clips → human review → final export → embedding. The system is built on functional architecture principles, with Elixir orchestration and Python for CV/ML/media processing, emphasizing modularity, maintainability, and production reliability.

### Virtual Clip Architecture

- **Universal Download**: Handles both web-scraped and user-uploaded videos
- **Proxy Generation**: Creates lossless master (FFV1/MKV, Glacier archival) and proxy (all-I-frame H.264, dual-purpose)
- **Virtual Clips**: Database records with cut points; no physical files until final export
- **Instant Review**: Server-side FFmpeg time segmentation with native HTML5 video for seeking and review actions (approve, skip, archive, group, cut point ops)  
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
- **Frontend**: Server-side FFmpeg streaming, native HTML5 video, modular JS, Phoenix LiveView

## Architecture Principles

- **Functional Domain Modeling & "I/O at the Edges"**: All business logic is implemented as pure, testable functions, isolated from side effects. I/O operations (database, S3, FFmpeg, Python tasks) are handled only at the boundaries of the system, in orchestration or adapter modules. This separation ensures code is predictable, easy to test, and maintainable, with clear boundaries between pure logic and external effects.
- **Declarative Pipeline Configuration**: Complete workflow defined as data in `PipelineConfig.stages()`, making it easy to see, modify, and test the entire pipeline flow without touching worker code.
- **Performance-First Optimizations**: Temp cache system eliminates 78% of S3 operations; direct job chaining eliminates dispatcher latency for FLAME environments.
- **Semantic Organization**: Clear distinction between user edits and automated artifacts
- **Direct Action Execution**: Review actions execute immediately; only simple UI-level undo (Ctrl+Z) remains
- **Centralized Configuration**: FFmpeg settings, S3 path management, and job chaining logic centralized in Elixir
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

### Declarative Job Chaining
- **Zero Dispatcher Latency**: Workers directly enqueue next stage upon completion
- **FLAME Environment Optimized**: Reduces pipeline latency from 3 minutes to milliseconds
- **Configuration-Driven**: All chaining logic defined in `PipelineConfig.stages()`
- **Graceful Fallback**: Failed chaining falls back to dispatcher-based processing
- **Centralized Logic**: Eliminates scattered chaining code across worker modules

## Key Design Decisions

### Enhanced Virtual Clips Organization

- **`virtual_clips/`**: Virtual clip management (core, cut point ops, MECE validation, audit trail)
- **`artifacts/`**: Artifact management and S3 path utilities
- **`shared/`**: Cross-context utilities (error handling)
- **`export/`**: Final encoding/export

### Centralized FFmpeg Configuration

- All encoding profiles and settings are managed in Elixir for consistency and maintainability.

### Direct Action Execution

- **Simple Actions**: `approve`, `skip`, `archive`, `group` execute instantly
- **Cut Point Operations**: `add_cut_point`, `remove_cut_point`, `move_cut_point` are instant DB transactions with audit trail
- **Undo**: Only simple UI-level undo (Ctrl+Z) for the most recent action

### Modular, Maintainable Codebase

- All modules are focused and single-responsibility
- Deprecated code, legacy features, and transitional logic have been removed
- Documentation and code structure are kept in sync

### Optimized Storage Strategy

**Dual-Purpose Proxy**: Single proxy file serves both CloudFront streaming review and final export, eliminating redundant file operations.

**Cost-Effective Archival**: Master stored in S3 Glacier (95% storage savings) for compliance/archival only.

**Export Performance**: Stream copy from proxy achieves 10x performance improvement with superior quality (CRF 20 vs deprecated CRF 23).

**I/O Optimization**: Direct S3 access via presigned URLs with byte-range seeking eliminates proxy download bottleneck.

## Context Responsibilities

- **`Videos`**: Source video lifecycle (download, preprocess, detect scenes, cache finalization)
- **`Clips`**: Virtual clip management, review workflow, artifact management, export
- **`Infrastructure`**: I/O adapters (S3, FFmpeg, Python), temp cache system, declarative pipeline configuration, worker behaviors
- **Python Tasks**: Media processing, scene detection, S3 operations, temp cache integration

## Production Reliability Features

- **Resumable Processing**: All stages support automatic resume after interruptions
- **Idempotent Workers**: Prevent duplicate work and handle retries gracefully
- **Centralized Error Handling**: Consistent error recovery and logging
- **Database Schema Robustness**: Consistent datetime handling, audit trails, and constraints

## Key Benefits

1. **Zero Re-encoding During Review**: Virtual clips are DB records only; instant operations
2. **Superior Quality**: Export from high-quality proxy (CRF 20) with zero transcoding loss
3. **Optimized I/O Performance**: 78% S3 operation reduction via temp caching; direct byte-range access
4. **FLAME Environment Ready**: Near-zero pipeline latency via declarative job chaining
5. **Universal Workflow**: Handles all ingest types with smart optimization detection
6. **True Virtual Clips**: Server-side FFmpeg time segmentation streams only exact clip ranges
7. **Instant Review**: Each clip feels like a standalone video file with 0-based timeline
8. **Maintainable Codebase**: Declarative configuration, modular design, centralized logic
9. **Production Reliable**: Resumable, idempotent, robust with graceful fallbacks

## Media Processing Configuration

### yt-dlp Download Strategy

The system uses a **quality-first download strategy** with robust fallback mechanisms to ensure best possible video quality (including 4K/8K when available).

⚠️  **CRITICAL**: Implementation details and requirements for maintaining 4K downloads are documented in `py/tasks/download_handler.py`. Do not modify format strings or client configurations without reviewing those requirements.

**Key Features**:
- Primary/fallback format strategy for maximum compatibility
- Playlist prevention and cache management
- Timeout handling and graceful degradation
- Normalization when needed for merge operations

**Expected Results**: ~49 available formats including 4K (2160p), 1440p, multiple 1080p options.