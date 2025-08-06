# AGENTS.md

Unified agent guidance for working with this codebase. See `lib/heaters/README.md` for complete architecture and workflow documentation.

## Tech Stack Overview

| Layer      | Technology & Version |
| ---------- | -------------------- |
| **Backend** | Elixir/Phoenix ~> 1.8.0 with LiveView ~> 1.1 |
| **Database** | PostgreSQL + `pgvector` extension |
| **Frontend** | Phoenix LiveView, vanilla JS, CSS |
| **Build** | `esbuild` for JavaScript bundling |
| **Job Queue** | Oban for background processing |
| **HTTP Client** | `:req` (Req) library - **avoid** `:httpoison`, `:tesla`, `:httpc` |
| **Deployment** | Docker‑containerized release |

## Development Commands

⚠️ **IMPORTANT**: All development commands should be run inside Docker containers for consistency. See "Development Environment & Testing" section below for comprehensive guidance.

- Use `mix precommit` alias when you are done with all changes and fix any pending issues

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

### Phoenix 1.8 Specific Guidelines
- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `HeatersWeb.Layouts` module is aliased in the `heaters_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">`) with your own values, no default classes are inherited, so your custom classes must fully style the input

### Router Guidelines
- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes
- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:
  ```elixir
  scope "/admin", HeatersWeb.Admin do
    pipe_through :browser
    live "/users", UserLive, :index
  end
  ```
  The UserLive route would point to the `HeatersWeb.Admin.UserLive` module
- `Phoenix.View` no longer is needed or included with Phoenix, don't use it

### Template Guidelines
- **HEEX files**: Use `.html.heex` extension for LiveView templates
- **Component naming**: Use snake_case for component names in templates
- **LiveView patterns**: Follow Phoenix LiveView conventions for state management
- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)

### HEEx Template Syntax
- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals:
  ```heex
  <%= cond do %>
    <% condition -> %>
      ...
    <% condition2 -> %>
      ...
    <% true -> %>
      ...
  <% end %>
  ```
- HEEx require special tag annotation if you want to insert literal curly braces like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:
  ```heex
  <code phx-no-curly-interpolation>
    let obj = {key: "val"}
  </code>
  ```
- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes:
  ```heex
  <a class={[
    "px-2 text-white",
    @some_flag && "py-5",
    if(@other_condition, do: "border-red-500", else: "border-blue-100")
  ]}>Text</a>
  ```
- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`
- **Never** write embedded `<script>` tags in HEEx. Instead always write your scripts and hooks in the `assets/js` directory and integrate them with the `assets/js/app.js` file

### Frontend Styling Guidelines
- **No Tailwind CSS**: Do not use Tailwind CSS or any utility-first CSS frameworks
- **Custom CSS**: Use traditional CSS with semantic class names and component-based styling
- **CSS organization**: Keep styles in `assets/css/` directory with logical file organization
- **Component styling**: Prefer scoped CSS classes that describe the component's purpose
- **Responsive design**: Use standard CSS media queries and flexbox/grid for layouts
- For "app wide" template imports, you can import/alias into the `heaters_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use HeatersWeb, :html`

### Database Patterns
- **Migrations**: Always review existing schema before proposing changes
- **Queries**: Use Ecto.Query for complex queries, prefer composable functions
- **Associations**: Use preloads judiciously, prefer explicit queries for performance. **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- **Indexes**: Consider query patterns when suggesting new indexes
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text` columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such an option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct

### Testing Patterns
- **Unit tests**: Test individual functions and modules
- **Integration tests**: Test complete workflows end-to-end
- **LiveView tests**: Test user interactions and state changes
- **Mock external services**: Use test doubles for S3, FFmpeg, Python calls

### LiveView Specific Guidelines
- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions in LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `HeatersWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `HeatersWeb` module, so you can just do `live "/weather", WeatherLive`
- Remember anytime you use `phx-hook="MyHook"` and that js hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute

### LiveView Streams
- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`
- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child:
  ```heex
  <div id="messages" phx-update="stream">
    <div :for={{id, msg} <- @streams.messages} id={id}>
      {msg.text}
    </div>
  </div>
  ```
- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**
- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use CSS classes:
  ```heex
  <div id="tasks" phx-update="stream">
    <div class="hidden only:block">No tasks yet</div>
    <div :for={{id, task} <- @stream.tasks} id={id}>
      {task.name}
    </div>
  </div>
  ```
- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### Form Handling Best Practices
- **Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms like this**:
  ```heex
  <%!-- ALWAYS do this (valid) --%>
  <.form for={@form} id="my-form">
    <.input field={@form[:field]} type="text" />
  </.form>
  ```
- **Never** access the changeset directly in templates:
  ```heex
  <%!-- NEVER do this (invalid) --%>
  <.form for={@changeset} id="my-form">
    <.input field={@changeset[:field]} type="text" />
  </.form>
  ```
- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset

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

### Variable Binding and Control Flow
- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression:
  ```elixir
  # INVALID: we are rebinding inside the `if` and the result never gets assigned
  if connected?(socket) do
    socket = assign(socket, :val, val)
  end

  # VALID: we rebind the result of the `if` to a new variable
  socket =
    if connected?(socket) do
      assign(socket, :val, val)
    end
  ```

### Common Mistakes to Avoid
- **No return statements**: The last expression in a block is always returned
- **Don't use `Enum` on large collections** when `Stream` is more appropriate
- **Avoid nested case statements** - refactor to a single case, with, or separate functions
- **Don't use `String.to_atom/1` on user input** (memory leak risk)
- **Lists cannot be indexed with brackets** - use pattern matching or Enum functions or `Enum.at/2`:
  ```elixir
  # NEVER do this (invalid):
  i = 0
  mylist = ["blue", "green"]
  mylist[i]

  # Instead, ALWAYS use Enum.at, pattern matching, or List functions:
  i = 0
  mylist = ["blue", "green"]
  Enum.at(mylist, i)
  ```
- **Prefer `Enum.reduce` over recursion**
- **Using the process dictionary is typically unidiomatic**
- **Only use macros if explicitly requested**
- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)

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
- **Use `Task.async_stream/3` for concurrent enumeration** with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`

## Testing Guidelines

### Mix Guidelines
- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

### Test Commands
- **Run specific file**: `mix test test/my_test.exs`
- **Run specific test**: `mix test path/to/test.exs:123`
- **Limit failures**: `mix test --max-failures n`
- **Tagged tests**: `mix test --only tag`
- **Previously failed tests**: `mix test --failed`

### Test Patterns
- **Use `assert_raise` for expected exceptions**: `assert_raise ArgumentError, fn -> invalid_function() end`
- **Unit tests**: Test individual functions and modules
- **Integration tests**: Test complete workflows end-to-end
- **LiveView tests**: Test user interactions and state changes
- **Mock external services**: Use test doubles for S3, FFmpeg, Python calls

### LiveView Testing
- Use `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** test against raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output:
  ```elixir
  html = render(view)
  document = LazyHTML.from_fragment(html)
  matches = LazyHTML.filter(document, "your-complex-selector")
  IO.inspect(matches, label: "Matches")
  ```

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