import Config

# ───────────────────────────────────────────
#  Database — local Docker Postgres for dev
# ───────────────────────────────────────────
config :frontend, Frontend.Repo,
  username: "dev_user",
  password: "dev_password",
  hostname: "app-db-dev",  # This is the service name from docker-compose.yaml
  database: "frontend_dev_db", # Matches POSTGRES_DB in app-db-dev service
  port: 5432,             # Port inside the Docker network for app-db-dev
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# ───────────────────────────────────────────
#  Phoenix endpoint
# ───────────────────────────────────────────
config :frontend, FrontendWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "1yyvat8bVNahXZFsX5tOvQ2sc75yXYCOC8dTG6pzDpBR4w32TTFftWpI+suyC1jc", # Replace with a new random string if you prefer
  watchers: [
    # Watch JS for changes
    npm: [
      "run",
      "watch:js",
      cd: Path.expand("../assets", __DIR__),
      # Add target for esbuild if it's not in your package.json script, though it is.
      # Example: node: ["esbuild.js", "--watch", "--target=es2017", output_path: "..."]
    ],
    # Watch CSS for changes
    npm: [
      "run",
      "watch:css",
      cd: Path.expand("../assets", __DIR__),
      # Example: tailwind: [Tailwind, :install_and_run, [:default, ~w(--watch)]]
    ]
  ]

# Live-reload patterns (your existing config is good)
config :frontend, FrontendWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css|png|jpeg|jpg|gif|svg)$", # Ensure this matches output dir
      ~r"priv/gettext/.*(po)$",
      ~r"lib/frontend_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :frontend, dev_routes: true
config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime # :runtime is good, :compile for releases
config :phoenix_live_view, :debug_heex_annotations, true

# Load .env in dev if you want overrides.
# Be careful that DATABASE_URL from .env doesn't override the static config above
# if you intend for dev.exs to define the dev database.
# One way to ensure dev.exs takes precedence for DB is to not set DATABASE_URL in .env for dev,
# or structure runtime.exs to only use DATABASE_URL if MIX_ENV is :prod.
# Your current runtime.exs always uses DATABASE_URL if set.
#
# if Code.ensure_loaded?(Dotenvy) and File.exists?(".env") do
#   Dotenvy.load()
# end
#
# Consider removing Dotenvy loading from dev.exs if docker-compose handles env vars,
# or ensure its load order/priority is as expected regarding database config.
# For the Phoenix frontend service, we are explicitly NOT relying on .env for DATABASE_URL.
