# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Core Mix Commands
- `mix setup` - Initial project setup (gets dependencies, sets up database)
- `mix dev.setup` - Docker-aware setup (starts containers, deps, database)
- `mix dev.server` - Start development server with Docker containers
- `mix dev.reset` - Reset development database with Docker containers
- `mix test` - Run tests (creates test database, runs migrations, then tests)
- `mix check` - Run quality checks (compile with warnings-as-errors, format check, tests)

### Code Quality
- `mix format` - Format Elixir code consistently
- `mix dialyzer` - Run static analysis for type checking
- `mix compile --warnings-as-errors` - Compile with strict warnings

### Assets
- `npm run deploy --prefix assets` - Build production assets
- `npm run watch:css --prefix assets` - Watch CSS changes
- `npm run watch:js --prefix assets` - Watch JavaScript changes

### Database
- `mix ecto.create` - Create database
- `mix ecto.migrate` - Run migrations
- `mix ecto.reset` - Drop and recreate database
- `mix ecto.setup` - Create, migrate, and seed database

### Python Environment
- `cd py && python -m venv venv` - Create Python virtual environment
- `source py/venv/bin/activate` - Activate Python environment
- `pip install -r py/requirements.txt` - Install Python dependencies

## Architecture Overview

### Technology Stack
- **Backend**: Elixir/Phoenix ~> 1.7.10 with LiveView ~> 1.0
- **Database**: PostgreSQL with pgvector extension for vector embeddings
- **Background Jobs**: Oban with PostgreSQL backend
- **Media Processing**: Hybrid approach - Native Elixir (Evision/OpenCV) + Python (ML/FFmpeg)
- **Storage**: AWS S3 with ExAws
- **Frontend**: Phoenix LiveView with vanilla JavaScript/CSS

### Core Domain Architecture

**Functional Domain Modeling**: "I/O at the edges" pattern with pure business logic separated from infrastructure

**Key Contexts**:
- `Videos` - Source video lifecycle from submission through clips creation
- `Clips` - Clip transformations and state management
- `Events` - Event sourcing infrastructure for review actions
- `Infrastructure` - I/O adapters and shared worker behaviors

### State Flow Pipeline
```
Source Video: new → downloading → downloaded → splicing → spliced
                                                    ↓
Clips: spliced → generating_sprite → pending_review → review_approved → keyframing → keyframed → embedding → embedded
                                          ↓
                                   review_archived (terminal)
```

### Semantic Operations Organization

**`Clips.Operations`** is organized by operation type:
- **`operations/edits/`** - User actions (Split, Merge) that create new clips
- **`operations/artifacts/`** - Pipeline stages (Sprite, Keyframe) that generate supplementary data

### Worker Architecture

**Centralized Worker Behavior**: All workers use `Infrastructure.Orchestration.WorkerBehavior` providing:
- Standardized performance monitoring and logging
- Consistent error handling with comprehensive stack traces
- Common idempotency patterns (`check_complete_states`, `check_artifact_exists`)
- Unified job lifecycle management

**Fully Declarative Pipeline**: `Infrastructure.Orchestration.PipelineConfig` defines workflow as data:
- Workers focus purely on domain logic
- Pipeline dispatcher handles ALL job orchestration
- Single source of truth for state transitions

### Hybrid Processing Strategy

**Native Elixir Scene Detection**: Uses Evision (OpenCV-Elixir bindings) for high-performance video processing without subprocess overhead

**Python ML/Media Processing**: Leverages mature Python ecosystem for ML embeddings and specialized media tasks

## Key Implementation Patterns

### Worker Implementation
```elixir
defmodule MyWorker do
  use Heaters.Infrastructure.Orchestration.WorkerBehavior, queue: :media_processing
  
  @impl WorkerBehavior
  def handle_work(args) do
    # Pure business logic - infrastructure handled by behavior
  end
end
```

### Structured Result Types
All operations return type-safe structs with `@enforce_keys`:
```elixir
%SpriteResult{status: "success", clip_id: 123, artifacts: [...], duration_ms: 1500}
%KeyframeResult{status: "success", keyframe_count: 8, strategy: "uniform"}
```

### Event Sourcing Pattern
Human review actions use CQRS:
- **Write-side**: `Events.Events` logs actions to `review_events` table
- **Read-side**: `Events.EventProcessor` processes events and orchestrates jobs

## Development Guidelines

### Code Style
- Follow existing functional architecture patterns
- Use "I/O at the edges" - keep business logic pure
- Implement idempotent worker patterns
- Return structured Result types with `@enforce_keys`
- Use centralized WorkerBehavior for all background jobs

### Database Changes
- Review existing Ecto schemas and migrations before proposing changes
- Use pgvector extension for vector embeddings
- Maintain consistent datetime handling across tables

### Python Integration
- Python tasks should be pure functions returning structured JSON
- No direct database access from Python code
- Use `Infrastructure.PyRunner` for Python task execution
- Python dependencies managed in `py/requirements.txt`

### Testing Approach
- Tests create isolated test database with migrations
- Use `test/support/data_case.ex` for database tests
- Use `test/support/conn_case.ex` for controller tests
- Mock external services (S3, Python tasks) in tests

## Common Tasks

### Running Single Tests
```bash
mix test test/path/to/specific_test.exs
mix test test/path/to/specific_test.exs:42  # specific line
```

### Database Console
```bash
mix ecto.gen.migration migration_name
mix ecto.migrate
iex -S mix  # Start IEx with application
```

### Background Job Monitoring
Jobs are managed by Oban with these queues:
- `default: 10` - General purpose
- `ingest: 3` - Video ingestion
- `media_processing: 5` - Media processing tasks
- `background_jobs: 2` - Dispatcher and archive
- `embeddings: 2` - ML embedding generation

### Docker Development
- `docker-compose up -d --wait` - Start development services
- Services defined in `docker-compose.yaml`
- Development workflow aliases are Docker-aware

## Key File Locations

### Core Application
- `lib/heaters/application.ex` - Application startup and supervision
- `lib/heaters/repo.ex` - Database repository
- `config/config.exs` - Base configuration
- `config/dev.exs` - Development configuration

### Domain Logic
- `lib/heaters/videos/` - Video processing domain
- `lib/heaters/clips/` - Clip management domain
- `lib/heaters/events/` - Event sourcing infrastructure
- `lib/heaters/infrastructure/` - I/O adapters and shared behaviors

### Web Interface
- `lib/heaters_web/live/` - LiveView components
- `lib/heaters_web/controllers/` - HTTP controllers
- `assets/` - Frontend assets (CSS, JavaScript)

### Background Processing
- `lib/heaters/infrastructure/orchestration/` - Pipeline configuration and dispatcher
- Workers are co-located with their respective domain contexts

### Python Integration
- `py/runner.py` - Python task runner
- `py/tasks/` - Python task implementations
- `py/requirements.txt` - Python dependencies