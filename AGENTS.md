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

### Documentation & Help
- `mix usage_rules.docs Module` - Search module documentation
- `mix usage_rules.docs Module.function` - Search specific function
- `mix usage_rules.search_docs "query"` - Search all package docs
- `mix help task_name` - Get docs for specific mix task

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

### Module Organization
- **Core modules**: `lib/heaters/` - Main business logic
- **Web layer**: `lib/heaters_web/` - Controllers, LiveView, templates
- **Infrastructure**: `lib/heaters/infrastructure/` - External adapters (S3, FFmpeg, Python)
- **Workers**: Background job implementations in respective modules
- **Shared utilities**: `lib/heaters/clips/shared/` - Common functionality

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
- Use `Infrastructure.PyRunner` for execution
- Complex tasks split into focused modules

## Environment Setup

- **Development vs Production**: Separate PostgreSQL instances and S3 buckets for dev/prod environments
- **Configuration**: Environment-specific settings handled through standard Phoenix configuration patterns

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