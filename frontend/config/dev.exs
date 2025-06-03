import Config

# ───────────────────────────────────────────
#  Database — local Docker Postgres for dev
# ───────────────────────────────────────────
# This configuration explicitly sets connection details for development,
# ensuring it connects to the 'app-db-dev' service regardless of
# a DATABASE_URL environment variable that might be loaded from .env.
config :frontend, Frontend.Repo,
  # Setup info matching docker-compose.yaml
  username: "dev_user",
  password: "dev_password",
  hostname: "app-db-dev",
  database: "frontend_dev_db",
  port: 5432,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10,
  # Typically SSL is not used for local Docker network connections
  ssl: false

# ───────────────────────────────────────────
#  Phoenix endpoint
# ───────────────────────────────────────────
config :frontend, FrontendWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  # Replace if sensitive or keep for dev
  secret_key_base: System.get_env("SECRET_KEY_BASE") || "1yyvat8bVNahXZFsX5tOvQ2sc75yXYCOC8dTG6pzDpBR4w32TTFftWpI+suyC1jc",
  watchers: [
    # Watch JS for changes
    npm: [
      "run",
      "watch:js",
      cd: Path.expand("../assets", __DIR__)
    ],
    # Watch CSS for changes
    npm: [
      "run",
      "watch:css",
      cd: Path.expand("../assets", __DIR__)
    ]
  ]

# Live-reload patterns
config :frontend, FrontendWeb.Endpoint,
  live_reload: [
    patterns: [
      # Ensure this matches output dir
      ~r"priv/static/assets/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/frontend_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Enable development-specific routes if you have them
config :frontend, dev_routes: true
config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, :debug_heex_annotations, true
