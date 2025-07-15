# AGENTS.md

Unified agent guidance for working with this codebase. See `lib/heaters/README.md` for complete architecture and workflow documentation.

## Tech Stack Overview

| Layer      | Technology & Version |
| ---------- | -------------------- |
| **Backend** | Elixir/Phoenix ~> 1.7.10 with LiveView ~> 1.0 |
| **Database** | PostgreSQL + `pgvector` extension |
| **Frontend** | Phoenix LiveView, vanilla JS, CSS |
| **Build** | `esbuild` for JavaScript bundling |
| **Job Queue** | Oban for background processing |
| **Deployment** | Docker‑containerized release |

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

## Guiding Principles

1. **Suggest, don't override**  
   Always think critically. If you see a more idiomatic, performant, or maintainable approach, **clearly label it as a suggestion**. Do **not** silently rewrite major parts without explicit alignment.

2. **Respect existing logic**  
   - Never remove or simplify business logic unless asked _or_ it's obviously broken—and then say so explicitly.  
   - Constants, parameters, and state machines (e.g. the `ingest_state` column) are sacrosanct until we both agree on changes.

3. **No placeholders, no stubs**  
   Any code you commit should compile and run. If credentials or secrets are required, insert `TODO` notes rather than dummy placeholders.

4. **Database changes require diligence**  
   Never propose schema changes (migrations, new indexes, altering columns) without first reviewing current Ecto schemas/migrations and spelling out the trade‑offs.

5. **Minimal, targeted edits**  
   Prefer surgical diffs over wholesale rewrites. If a full‑file replacement is unavoidable, explain why first.

## Architecture Patterns

- **"I/O at the edges"**: Keep business logic pure, isolate I/O in operations/adapters
- **Structured Results**: Always return type-safe structs with `@enforce_keys`
- **Worker Pattern**: Use `Infrastructure.Orchestration.WorkerBehavior` for all background jobs
- **Semantic Organization**: `operations/edits/` (user actions) vs `operations/artifacts/` (pipeline stages)
- **Job Orchestration**: All background processing orchestrated through Oban job queue
- **Frontend Minimalism**: Leverage LiveView capabilities; minimize JavaScript usage

## Code Implementation Guidelines

- Follow functional architecture with pure domain logic
- Database I/O appropriate in operations modules
- External I/O (S3, FFmpeg, Python) isolated in infrastructure adapters
- All workers implement idempotent patterns
- Return structured Result types, not raw maps

## Python Integration

- **Minimize Python usage**: Keep Python code minimal and focused on specific tasks
- **Keep logic in Elixir**: Business logic should remain in Elixir wherever possible
- Python tasks are pure functions returning structured JSON
- No direct database access from Python
- Use `Infrastructure.PyRunner` for execution
- Complex tasks split into focused modules

## Testing

- **Run tests after changes**: Execute `mix test` after making changes
- **Update test relevance**: Check if tests are still relevant and update if needed
- Use `test/support/data_case.ex` for database tests
- Use `test/support/conn_case.ex` for controller tests
- Mock external services (S3, Python tasks)

## Environment Setup

- **Development vs Production**: Separate PostgreSQL instances and S3 buckets for dev/prod environments
- **Configuration**: Environment-specific settings handled through standard Phoenix configuration patterns

## Typical Workflow

1. **Understand** the request.
2. **Validate** the implied approach; suggest improvements if warranted.
3. **Implement** via minimal diff or new file.
4. **Run** formatter & `mix check`; fix issues.
5. **Test** the implementation with `mix test`.
6. **Update documentation**: Update README or relevant docs if changes require it.
7. **Deliver** code with explanation & next‑steps.