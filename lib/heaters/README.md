# Heaters Video Processing Pipeline

## Overview

Heaters processes videos through a multi-stage pipeline: ingestion → clips → human review → approval → embedding. The system emphasizes functional architecture with "I/O at the edges", event sourcing for human actions, and clean separation between media processing (Python) and business logic (Elixir).

## Architecture Principles

- **Functional Domain Modeling**: "I/O at the edges" with pure business logic separated from I/O operations
- **Semantic Organization**: Clear distinction between user **Edits** (review actions) and automated **Artifacts** (pipeline stages)
- **Event Sourcing**: Human review actions tracked via `clip_events` table for audit and reliability
- **Structured Results**: Type-safe Result structs with rich metadata and performance timing
- **Generic Workers**: Standardized Oban worker behavior eliminates boilerplate

## State Flow

```
Source Video: new → downloading → downloaded → splicing → spliced
                                                    ↓
Clips: spliced → generating_sprite → pending_review → review_approved → keyframing → keyframed → embedding → embedded
                                          ↓
                                   review_archived (terminal)
                                          ↓
                                   merge/split → new clips → generating_sprite
```

## Key Design Decisions

### Semantic Operations Organization

The `Clips.Operations` context is organized by **operation type**, not file type:

- **`operations/edits/`**: User actions that create new clips and enter review workflow
  - `Merge`, `Split` operations (write to `clips` table)
- **`operations/artifacts/`**: Pipeline stages that generate supplementary data  
  - `Sprite`, `Keyframe`, `ClipArtifact` operations (write to `clip_artifacts` table)

This reflects the fundamental difference between human review actions and automated processing stages.

### Event Sourcing for Review Actions

Human review actions use CQRS pattern:
- **Write-side**: `Events.Events` logs all actions to `clip_events` table
- **Read-side**: `Events.EventProcessor` processes events and orchestrates follow-up jobs
- **Benefits**: Audit trail, reliable job queuing, ability to replay/undo actions

### Functional Architecture with "I/O at the Edges"

Operations follow Domain Modeling Made Functional principles:

```
Pure Domain Logic (testable, no I/O)
    ↓
I/O Orchestration (Operations modules)
    ↓  
Infrastructure Adapters (S3, FFmpeg, Database)
```

**Benefits**: Testable business logic, predictable functions, clear separation of concerns.

### Python Task Interface

Python tasks are pure media processing functions with no database access:

```python
def run_task_name(explicit_params, **kwargs) -> dict:
    # Pure media processing - no DB connections
    # Return structured JSON for Elixir processing
```

### Structured Result Types

All operations return type-safe structs with `@enforce_keys`:

```elixir
%SpriteResult{status: "success", clip_id: 123, artifacts: [...], duration_ms: 1500}
%KeyframeResult{status: "success", keyframe_count: 8, strategy: "uniform"}
%MergeResult{status: "success", merged_clip_id: 456, cleanup: %{...}}
```

**Benefits**: Compile-time validation, rich metadata, direct field access without defensive `Map.get`.

## Workflow Examples

### Video Ingestion
1. `Videos.submit/1` creates source video in `new` state
2. `Videos.IngestWorker` downloads/processes → `downloaded` state  
3. `Videos.SpliceWorker` splits into clips → clips in `spliced` state

### Review Workflow
1. `Clips.SpriteWorker` generates sprites → clips in `pending_review` state
2. Human reviews and takes actions (approve/archive/merge/split)
3. Actions logged via event sourcing, new clips automatically flow back through pipeline

### Post-Approval Processing
1. `Clips.KeyframeWorker` extracts keyframes → `keyframed` state
2. `Clips.EmbeddingWorker` generates ML embeddings → `embedded` state (final)

## Orchestration

**Dispatcher** runs periodically with data-driven step definitions:
1. Find work (e.g., `new` videos, `spliced` clips)
2. Enqueue appropriate workers
3. Process pending events via `EventProcessor.commit_pending_actions/0`

This pattern reduced orchestration code from 98 to 42 lines through configuration over code.

## Context Responsibilities

- **`Videos`**: Source video lifecycle from submission through clips creation
- **`Clips.Operations`**: Clip transformations and state management (semantic Edits/Artifacts organization)
- **`Clips.Review`**: Human review workflow and action coordination  
- **`Clips.Embeddings`**: ML embedding generation and queries
- **`Events`**: Event sourcing infrastructure for review actions
- **`Infrastructure`**: I/O adapters (S3, FFmpeg, Database) with consistent interfaces

## Key Benefits

1. **Clear Separation**: Media processing vs business logic vs I/O operations
2. **Maintainable**: Functional architecture with pure domain logic
3. **Reliable**: Event sourcing and structured error handling
4. **Type-Safe**: Structured results with compile-time validation  
5. **Testable**: Pure functions without I/O dependencies
6. **Semantic**: Operations organized by business purpose, not implementation details 