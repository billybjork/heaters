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

- **Functional Domain Modeling & “I/O at the Edges”**: All business logic is implemented as pure, testable functions, isolated from side effects. I/O operations (database, S3, FFmpeg, Python tasks) are handled only at the boundaries of the system, in orchestration or adapter modules. This separation ensures code is predictable, easy to test, and maintainable, with clear boundaries between pure logic and external effects.
- **Semantic Organization**: Clear distinction between user edits and automated artifacts
- **Direct Action Execution**: Review actions execute immediately; only simple UI-level undo (Ctrl+Z) remains
- **Centralized Configuration**: FFmpeg settings and S3 path management centralized in Elixir
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

- **`Videos`**: Source video lifecycle (download, preprocess, detect scenes)
- **`Clips`**: Virtual clip management, review workflow, artifact management, export
- **`Infrastructure`**: I/O adapters (S3, FFmpeg, Python), centralized configuration, worker behaviors
- **Python Tasks**: Media processing, scene detection, S3 operations

## Production Reliability Features

- **Resumable Processing**: All stages support automatic resume after interruptions
- **Idempotent Workers**: Prevent duplicate work and handle retries gracefully
- **Centralized Error Handling**: Consistent error recovery and logging
- **Database Schema Robustness**: Consistent datetime handling, audit trails, and constraints

## Key Benefits

1. **Zero Re-encoding During Review**: Virtual clips are DB records only; instant operations
2. **Superior Quality**: Export from high-quality proxy (CRF 20) with zero transcoding loss
3. **I/O Efficiency**: Direct S3 byte-range access eliminates download bottlenecks
4. **Universal Workflow**: Handles all ingest types
5. **True Virtual Clips**: Server-side FFmpeg time segmentation streams only exact clip ranges
6. **Instant Review**: Each clip feels like a standalone video file with 0-based timeline
7. **Maintainable Codebase**: Modular, focused, and up-to-date
8. **Production Reliable**: Resumable, idempotent, and robust