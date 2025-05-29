import Config

# ───────────────────────────────────────────
#  Database — local Postgres for dev only
# ───────────────────────────────────────────
config :frontend, Frontend.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "frontend_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# ───────────────────────────────────────────
#  Phoenix endpoint
# ───────────────────────────────────────────
config :frontend, FrontendWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "1yyvat8bVNahXZFsX5tOvQ2sc75yXYCOC8dTG6pzDpBR4w32TTFftWpI+suyC1jc",
  watchers: []

# Live-reload patterns
config :frontend, FrontendWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/frontend_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :frontend, dev_routes: true
config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, :debug_heex_annotations, true

# Load .env in dev if you want overrides (e.g. DATABASE_URL)
if Code.ensure_loaded?(Dotenvy) and File.exists?(".env") do
  Dotenvy.load()
end
