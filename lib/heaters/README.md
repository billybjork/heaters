# Heaters Video Processing Pipeline

## Overview

Heaters processes videos through a **virtual clip pipeline**: download → proxy generation → virtual clips → human review → final export → embedding. The system is built on functional architecture principles, with Elixir orchestration and Python for CV/ML/media processing, emphasizing modularity, maintainability, and production reliability.

### Virtual Clip Architecture

- **Universal Download**: Handles both web-scraped and user-uploaded videos
- **Proxy Generation**: Creates lossless gold master (FFV1/MKV) and review proxy (all-I-frame H.264)
- **Virtual Clips**: Database records with cut points; no physical files until final export
- **Instant Review**: WebCodecs-based seeking and review actions (approve, skip, archive, group, cut point ops)
- **Final Export**: High-quality encoding from gold master after review approval

**Key Benefits**: Zero re-encoding during review, lossless quality, instant operations, universal workflow, maintainable codebase.

### Technology Stack
- **Backend**: Elixir/Phoenix with LiveView
- **Database**: PostgreSQL with pgvector
- **Scene Detection**: Python OpenCV via PyRunner
- **Keyframe Extraction**: Native Elixir FFmpeg
- **ML Processing**: Python (PyTorch, Transformers)
- **Media Processing**: Python (yt-dlp, FFmpeg)
- **Storage**: AWS S3
- **Frontend**: WebCodecs API, modular JS, Phoenix LiveView

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
2. **Lossless Quality**: Final export from gold master
3. **Universal Workflow**: Handles all ingest types
4. **Instant Review**: WebCodecs-based seeking and review
5. **Maintainable Codebase**: Modular, focused, and up-to-date
6. **Production Reliable**: Resumable, idempotent, and robust

---

## Implementation Status

- **Virtual Clip Backend Pipeline**: Complete
- **WebCodecs Player**: Modular JS, frame-perfect seeking
- **Review UI**: LiveView with instant cut point ops and group action
- **Python Tasks**: Modular, utility-based organization
- **S3 Integration**: Centralized and robust
- **Code Quality**: Deprecated code removed, all modules up to date

---

For more details, see `enhanced_virtual_clips_refactor.md`. 