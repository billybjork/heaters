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

⚠️ **IMPORTANT**: All development commands should be run inside Docker containers for consistency. See "Development Environment & Testing" section below for comprehensive guidance.

### Quick Health Check (Run This First)
```bash
docker-compose run --rm app mix compile --warnings-as-errors && \
docker-compose run --rm -e MIX_ENV=test app mix test && \
docker-compose run --rm app mix run -e 'IO.puts("✅ Environment: #{Application.get_env(:heaters, :app_env)}"); IO.puts("✅ CloudFront: #{Application.get_env(:heaters, :cloudfront_domain)}"); IO.puts("✅ S3 Bucket: #{Application.get_env(:heaters, :s3_bucket)}")'
```

### Core Commands
- `docker-compose run --rm app mix dev.setup` - Docker-aware setup (starts containers, deps, database)
- `docker-compose up app` - Start development server with Docker containers
- `docker-compose run --rm -e MIX_ENV=test app mix test` - Run tests 
- `docker-compose run --rm app mix compile --warnings-as-errors` - Quality check compilation

### Code Quality
- `docker-compose run --rm app mix format` - Format code
- `docker-compose run --rm app mix dialyzer` - Static analysis
- `docker-compose run --rm app mix compile --warnings-as-errors` - Strict compilation

### Documentation & Help
- `docker-compose run --rm app mix usage_rules.docs Module` - Search module documentation
- `docker-compose run --rm app mix usage_rules.docs Module.function` - Search specific function
- `docker-compose run --rm app mix usage_rules.search_docs "query"` - Search all package docs
- `docker-compose run --rm app mix help task_name` - Get docs for specific mix task

## Guiding Principles

1. **Suggest, don't override**  
   Always think critically. If you see a more idiomatic, performant, or maintainable approach, **clearly label it as a suggestion**. Do **not** silently rewrite major parts without explicit alignment.

2. **Respect existing logic**  
   - Never remove or simplify business logic unless asked _or_ it's obviously broken—and then say so explicitly.  
   - Constants, parameters, and state machines (e.g. the `ingest_state` column) are sacrosanct until we both agree on changes.

3. **Maintain consistency across similar operations**  
   - **Before implementing**: Search for existing patterns for the same type of operation (e.g., "how do other parts get source video title?")
   - **Data access patterns**: If one module uses database lookups for source video titles, other modules should use the same pattern, not preloaded associations
   - **S3 path structures**: Ensure consistent directory naming across operations (clips, artifacts, etc.)
   - **Error handling**: Use the same error handling patterns for similar failure scenarios
   - **When in doubt**: Grep for existing implementations before writing new code

4. **No placeholders, no stubs**  
   Any code you commit should compile and run. If credentials or secrets are required, insert `TODO` notes rather than dummy placeholders.

5. **Database changes require diligence**  
   Never propose schema changes (migrations, new indexes, altering columns) without first reviewing current Ecto schemas/migrations and spelling out the trade‑offs.

6. **Minimal, targeted edits**  
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

## Elixir/Phoenix Specific Guidelines

### Template Guidelines
- **HEEX files**: Use `.html.heex` extension for LiveView templates
- **Component naming**: Use snake_case for component names in templates
- **LiveView patterns**: Follow Phoenix LiveView conventions for state management
- **CSS classes**: Use semantic class names, prefer utility-first approach

### Frontend Styling Guidelines
- **No Tailwind CSS**: Do not use Tailwind CSS or any utility-first CSS frameworks
- **Custom CSS**: Use traditional CSS with semantic class names and component-based styling
- **CSS organization**: Keep styles in `assets/css/` directory with logical file organization
- **Component styling**: Prefer scoped CSS classes that describe the component's purpose
- **Responsive design**: Use standard CSS media queries and flexbox/grid for layouts

### Database Patterns
- **Migrations**: Always review existing schema before proposing changes
- **Queries**: Use Ecto.Query for complex queries, prefer composable functions
- **Associations**: Use preloads judiciously, prefer explicit queries for performance
- **Indexes**: Consider query patterns when suggesting new indexes

### Testing Patterns
- **Unit tests**: Test individual functions and modules
- **Integration tests**: Test complete workflows end-to-end
- **LiveView tests**: Test user interactions and state changes
- **Mock external services**: Use test doubles for S3, FFmpeg, Python calls

## Elixir Core Usage Rules

### Pattern Matching
- **Use pattern matching over conditional logic** when possible
- **Prefer function heads** instead of using if/else or case in function bodies
- **Use guard clauses**: `when is_binary(name) and byte_size(name) > 0`

### Error Handling
- **Use `{:ok, result}` and `{:error, reason}` tuples** for operations that can fail
- **Avoid raising exceptions for control flow**
- **Use `with` for chaining operations** that return `{:ok, _}` or `{:error, _}`

### Function Design
- **Use multiple function clauses** over complex conditional logic
- **Name functions descriptively**: `calculate_total_price/2` not `calc/2`
- **Predicate functions should end with `?`**: `valid?/1`, `empty?/1`
- **Reserve `is_` prefix for guards only**

### Data Structures
- **Use structs over maps** when the shape is known: `defstruct [:name, :age]`
- **Prefer keyword lists for options**: `[timeout: 5000, retries: 3]`
- **Use maps for dynamic key-value data**
- **Prefer to prepend to lists** `[new | list]` not `list ++ [new]`

### Common Mistakes to Avoid
- **No return statements**: The last expression in a block is always returned
- **Don't use `Enum` on large collections** when `Stream` is more appropriate
- **Avoid nested case statements** - refactor to a single case, with, or separate functions
- **Don't use `String.to_atom/1` on user input** (memory leak risk)
- **Lists cannot be indexed with brackets** - use pattern matching or Enum functions
- **Prefer `Enum.reduce` over recursion**
- **Using the process dictionary is typically unidiomatic**
- **Only use macros if explicitly requested**

## OTP Usage Rules

### GenServer Best Practices
- **Keep state simple and serializable**
- **Handle all expected messages explicitly**
- **Use `handle_continue/2` for post-init work**
- **Implement proper cleanup in `terminate/2` when necessary**

### Process Communication
- **Use `GenServer.call/3` for synchronous requests** expecting replies
- **Use `GenServer.cast/2` for fire-and-forget messages**
- **When in doubt, use call over cast** to ensure back-pressure
- **Set appropriate timeouts for call/3 operations**

### Fault Tolerance
- **Set up processes to handle crashing and restarting** by supervisors
- **Use `:max_restarts` and `:max_seconds`** to prevent restart loops

### Task and Async
- **Use `Task.Supervisor` for better fault tolerance**
- **Handle task failures** with `Task.yield/2` or `Task.shutdown/2`
- **Set appropriate task timeouts**
- **Use `Task.async_stream/3` for concurrent enumeration** with back-pressure

## Testing Guidelines

### Test Commands
- **Run specific file**: `mix test test/my_test.exs`
- **Run specific test**: `mix test path/to/test.exs:123`
- **Limit failures**: `mix test --max-failures n`
- **Tagged tests**: `mix test --only tag`

### Test Patterns
- **Use `assert_raise` for expected exceptions**: `assert_raise ArgumentError, fn -> invalid_function() end`
- **Unit tests**: Test individual functions and modules
- **Integration tests**: Test complete workflows end-to-end
- **LiveView tests**: Test user interactions and state changes
- **Mock external services**: Use test doubles for S3, FFmpeg, Python calls

## Python Integration

- **Minimize Python usage**: Keep Python code minimal and focused on specific tasks
- **Keep logic in Elixir**: Business logic should remain in Elixir wherever possible
- Python tasks are pure functions returning structured JSON
- No direct database access from Python
- Complex tasks split into focused modules

## Development Environment & Testing

### Environment Variable Architecture
- **CRITICAL RULE**: Application code should NEVER directly access environment variables via `System.get_env/1`
- **Proper Flow**: Environment variables → Config files (`config/dev.exs`, `config/runtime.exs`) → Application config (`Application.get_env/2`)
- **Centralized Config**: All environment-specific values flow through the application configuration system

### Environment Variable Naming Convention
- **Consistent Prefix Pattern**: Use `DEV_` and `PROD_` prefixes for all environment-specific variables
- **Current Variables**:
  - `DEV_DATABASE_URL` / `PROD_DATABASE_URL`
  - `DEV_S3_BUCKET_NAME` / `PROD_S3_BUCKET_NAME` 
  - `DEV_CLOUDFRONT_DOMAIN` / `PROD_CLOUDFRONT_DOMAIN`

### Docker Development Setup
Before running any commands, ensure Docker containers are running:

```bash
# Start development environment
docker-compose up -d

# Check container status
docker-compose ps

# View logs if needed
docker-compose logs app
```

### Essential Testing Commands

#### Quick Health Check
```bash
# Comprehensive verification (run all at once)
docker-compose run --rm app mix compile --warnings-as-errors && \
docker-compose run --rm -e MIX_ENV=test app mix test && \
docker-compose run --rm app mix run -e 'IO.puts("✅ Environment: #{Application.get_env(:heaters, :app_env)}"); IO.puts("✅ CloudFront: #{Application.get_env(:heaters, :cloudfront_domain)}"); IO.puts("✅ S3 Bucket: #{Application.get_env(:heaters, :s3_bucket)}")'
```

#### Individual Components
```bash
# Test compilation
docker-compose run --rm app mix compile --warnings-as-errors

# Test database connectivity
docker-compose run --rm app mix run -e 'alias Heaters.Repo; import Ecto.Query; count = from(v in "source_videos") |> Repo.aggregate(:count); IO.puts("Database connection: ✅ Working, #{count} videos")'

# Run tests
docker-compose run --rm -e MIX_ENV=test app mix test

# Test configuration loading
docker-compose run --rm app mix run -e 'IO.puts("App env: #{Application.get_env(:heaters, :app_env)}"); IO.puts("CloudFront: #{Application.get_env(:heaters, :cloudfront_domain)}"); IO.puts("S3 bucket: #{Application.get_env(:heaters, :s3_bucket)}")'

# Code formatting check
docker-compose run --rm app mix format --check-formatted
```

### Database Operations
```bash
# Create databases (if needed)
docker-compose run --rm app mix ecto.create
docker-compose run --rm -e MIX_ENV=test app mix ecto.create

# Run migrations
docker-compose run --rm app mix ecto.migrate
docker-compose run --rm -e MIX_ENV=test app mix ecto.migrate

# Reset database (DEV ONLY)
docker-compose run --rm app mix ecto.reset
```

### Development Server
```bash
# Start Phoenix server (accessible at http://localhost:4000)
docker-compose up app

# Or run in background
docker-compose up -d app
```

### Troubleshooting Common Issues

#### Container Won't Start
```bash
# Check logs
docker-compose logs app

# Rebuild container
docker-compose build app

# Clean restart
docker-compose down && docker-compose up -d
```

#### Environment Variable Issues
```bash
# Verify .env file exists and has correct variables
cat .env

# Check if variables are being passed to container
docker-compose run --rm app printenv | grep -E "(DEV_|PROD_|APP_ENV)"
```

#### Database Connection Issues
```bash
# Test database container health
docker-compose exec app-db-dev pg_isready

# Check database configuration
docker-compose run --rm app mix run -e 'IO.inspect(Application.get_env(:heaters, Heaters.Repo))'
```

### Development Best Practices
- **Always verify the environment is working** before starting development work
- **Run the health check** if you encounter any configuration-related issues
- **Use Docker containers** for all development commands to ensure consistency
- **Test in both dev and test environments** when making configuration changes

## File Type Associations

- **HEEX templates**: `.html.heex` files should be treated as HTML with embedded Elixir
- **Elixir files**: `.ex` and `.exs` files follow standard Elixir conventions
- **Configuration**: `config/` files use Elixir configuration syntax
- **JavaScript**: `assets/js/` files for frontend interactivity
- **CSS**: `assets/css/` files for styling

## Typical Workflow

1. **Understand** the request.
2. **Validate** the implied approach; suggest improvements if warranted.
3. **Implement** via minimal diff or new file.
4. **Run** formatter & `mix check`; fix issues.
5. **Test** the implementation with `mix test`.
6. **Update documentation**: Update README or relevant docs if changes require it.
7. **Deliver** code with explanation & next‑steps.