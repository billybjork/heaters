# AGENTS.md

See `lib/heaters/README.md` for complete architecture and workflow documentation.

## Tech Stack

| Layer      | Technology |
| ---------- | ---------- |
| **Backend** | Elixir/Phoenix ~> 1.8.0 with LiveView ~> 1.1 |
| **Database** | PostgreSQL + `pgvector` extension |
| **Frontend** | Phoenix LiveView, vanilla JS, CSS (no Tailwind) |
| **Build** | `esbuild` for JavaScript bundling |
| **Job Queue** | Oban for background processing |
| **HTTP Client** | `:req` (Req) library -- **avoid** `:httpoison`, `:tesla`, `:httpc` |
| **Deployment** | Docker-containerized release |

## Development Commands

All commands run inside Docker containers:

```bash
# Quality check (compile + format + test)
docker-compose run --rm app mix check

# Individual commands
docker-compose run --rm app mix compile --warnings-as-errors
docker-compose run --rm app mix format
docker-compose run --rm app mix dialyzer
docker-compose run --rm -e MIX_ENV=test app mix test

# Development server
docker-compose up app

# Setup / reset
docker-compose run --rm app mix dev.setup
docker-compose run --rm app mix dev.reset
```

## Guiding Principles

1. **Suggest, don't override**
   If you see a better approach, clearly label it as a suggestion. Do not silently rewrite major parts without explicit alignment.

2. **Respect existing logic**
   - Never remove or simplify business logic unless asked or it's obviously broken.
   - State machines (e.g. `ingest_state`) are sacrosanct until we agree on changes.

3. **Maintain consistency across similar operations**
   - Search for existing patterns before implementing (e.g., "how do other modules get source video title?")
   - Keep data access patterns, S3 path structures, and error handling consistent.

4. **No placeholders, no stubs**
   Code must compile and run. Use `TODO` notes for missing credentials.

5. **Database changes require diligence**
   Review current schemas/migrations and spell out trade-offs before proposing changes.

6. **Minimal, targeted edits**
   Prefer surgical diffs over wholesale rewrites.

## Architecture Patterns

- **"I/O at the edges"**: Keep business logic pure, isolate I/O in adapters
- **Structured Results**: Return type-safe structs with `@enforce_keys`, not raw maps
- **Worker Pattern**: Use `Heaters.Pipeline.WorkerBehavior` for all background jobs
- **Job Orchestration**: All background processing through Oban
- **Frontend Minimalism**: Leverage LiveView; minimize JavaScript
- **No Tailwind CSS**: Use traditional CSS with semantic class names in `assets/css/`

## Code Guidelines

- Functional architecture with pure domain logic
- External I/O (S3, FFmpeg, Python) isolated in infrastructure adapters
- All workers implement idempotent patterns
- Application code should never access env vars via `System.get_env/1` directly -- use `Application.get_env/2` (env vars flow through `config/` files)

## Phoenix-Specific Notes

- `<Layouts.app flash={@flash}>` wraps all LiveView content (aliased in `heaters_web.ex`)
- `<.flash_group>` only in `layouts.ex`
- Use `<.icon name="hero-x-mark">` for icons, `<.input>` for form inputs from `core_components.ex`
- Avoid LiveComponents unless there's a strong need
- Never use deprecated `live_redirect`/`live_patch` -- use `<.link navigate={}>` / `push_navigate`
- Router `scope` blocks already provide module aliases -- don't duplicate them
- No embedded `<script>` tags in HEEx -- put JS in `assets/js/`

## Python Integration

- Keep Python minimal and focused on specific tasks (yt-dlp, OpenCV, ONNX)
- Business logic stays in Elixir
- Python tasks are pure functions returning structured JSON
- No direct database access from Python
