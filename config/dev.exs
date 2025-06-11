import Config

# ───────────────────────────────────────────
#  Database — local Docker Postgres for dev
# ───────────────────────────────────────────
# Configuration for development database connection to the Docker container
# These settings match the PostgreSQL service defined in docker-compose.yaml
config :frontend, Frontend.Repo,
  username: "dev_user",
  password: "dev_password",
  hostname: "app-db-dev",
  database: "frontend_dev_db",
  port: 5432,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10,
  ssl: false

# ───────────────────────────────────────────
#  Phoenix endpoint
# ───────────────────────────────────────────
config :frontend, FrontendWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "1yyvat8bVNahXZFsX5tOvQ2sc75yXYCOC8dTG6pzDpBR4w32TTFftWpI+suyC1jc",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]}
  ]

# Watch static assets for browser reloading.
config :frontend, FrontendWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/frontend_web/(live|views)/.*(ex)$",
      ~r"lib/frontend_web/templates/.*(eex)$"
    ]
  ]

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Disable dev compilation for static assets
config :phoenix, :format_version, "3.0"

# ───────────────────────────────────────────
#  Oban Configuration
# ───────────────────────────────────────────
# Configure Oban for background job processing
# - Sets up a cron job to run the Dispatcher every minute
# - Defines queue concurrency limits for different job types
config :frontend, Oban,
  repo: Frontend.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Frontend.Workers.Dispatcher}
     ]}
  ],
  queues: [
    default: 10,
    ingest: 5,
    media_processing: 8,
    events: 20,
    media: 5,
    embeddings: 5,
    background_jobs: 2
  ]

# Enable development-specific routes if you have them
config :frontend, dev_routes: true

# Configure PythonRunner for development
config :frontend, Frontend.PythonRunner,
  python_executable: System.find_executable("python3") || "python3",
  working_dir: Path.expand("."),  # Current directory for local dev
  runner_script: "py_tasks/runner.py"
