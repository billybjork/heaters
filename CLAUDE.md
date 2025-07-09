# CLAUDE.md

Claude-specific guidance for working with this codebase. See `lib/heaters/README.md` for complete architecture and workflow documentation.

## Development Commands

### Core Commands
- `mix dev.setup` - Docker-aware setup (starts containers, deps, database)
- `mix dev.server` - Start development server with Docker containers
- `mix test` - Run tests 
- `mix check` - Run quality checks (compile with warnings-as-errors, format check, tests)

### Code Quality
- `mix format` - Format code
- `mix dialyzer` - Static analysis
- `mix compile --warnings-as-errors` - Strict compilation

## Key Claude-Specific Guidelines

### Architecture Patterns
- **"I/O at the edges"**: Keep business logic pure, isolate I/O in operations/adapters
- **Structured Results**: Always return type-safe structs with `@enforce_keys`
- **Worker Pattern**: Use `Infrastructure.Orchestration.WorkerBehavior` for all background jobs
- **Semantic Organization**: `operations/edits/` (user actions) vs `operations/artifacts/` (pipeline stages)

### Code Implementation
- Follow functional architecture with pure domain logic
- Database I/O appropriate in operations modules
- External I/O (S3, FFmpeg, Python) isolated in infrastructure adapters
- All workers implement idempotent patterns
- Return structured Result types, not raw maps

### Python Integration
- Python tasks are pure functions returning structured JSON
- No direct database access from Python
- Use `Infrastructure.PyRunner` for execution
- Complex tasks split into focused modules

### Testing
- Use `test/support/data_case.ex` for database tests
- Use `test/support/conn_case.ex` for controller tests
- Mock external services (S3, Python tasks)