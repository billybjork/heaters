import Config

# ───────────────────────────────────────────
#  Database — local Docker Postgres for dev
# ───────────────────────────────────────────
# Configuration for development database connection
# Supports both DATABASE_URL and individual connection parameters

# First try DEV_DATABASE_URL from .env, then fall back to individual parameters
case System.get_env("DEV_DATABASE_URL") do
  nil ->
    # Fallback to individual connection parameters
    # Check if we're running inside Docker or have Docker Compose running
    in_docker = System.get_env("DOCKER_ENV") == "true"
    use_docker_db = System.get_env("USE_DOCKER_DB") != "false"

    {hostname, port} =
      cond do
        in_docker ->
          # Running inside Docker container, connect to service name
          {"app-db-dev", 5432}

        use_docker_db ->
          # Running locally but using Docker Compose database
          {"localhost", 5433}

        true ->
          # Local PostgreSQL setup
          {"localhost", 5432}
      end

    config :heaters, Heaters.Repo,
      username: System.get_env("DEV_DB_USER") || "dev_user",
      password: System.get_env("DEV_DB_PASSWORD") || "dev_password",
      hostname: System.get_env("DEV_DB_HOST") || hostname,
      database: System.get_env("DEV_DB_NAME") || "heaters_dev_db",
      port: System.get_env("DEV_DB_PORT") |> then(&if &1, do: String.to_integer(&1), else: port),
      stacktrace: true,
      show_sensitive_data_on_connection_error: true,
      pool_size: String.to_integer(System.get_env("DEV_DB_POOL_SIZE") || "10"),
      ssl: false,
      # Performance optimizations for development
      timeout: 15_000,
      queue_target: 5000,
      queue_interval: 1000,
      # Disable query logging for cleaner logs
      log: false

  dev_database_url ->
    # Use DEV_DATABASE_URL from .env (preferred method)
    config :heaters, Heaters.Repo,
      url: dev_database_url,
      stacktrace: true,
      show_sensitive_data_on_connection_error: true,
      pool_size: String.to_integer(System.get_env("DEV_DB_POOL_SIZE") || "10"),
      # Performance optimizations for development
      timeout: 15_000,
      queue_target: 5000,
      queue_interval: 1000,
      # Disable query logging for cleaner logs
      log: false
end

# ───────────────────────────────────────────
#  Phoenix endpoint
# ───────────────────────────────────────────
config :heaters, HeatersWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "1yyvat8bVNahXZFsX5tOvQ2sc75yXYCOC8dTG6pzDpBR4w32TTFftWpI+suyC1jc",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]}
  ]

# Watch static assets for browser reloading.
config :heaters, HeatersWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"assets/css/.*(css)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/heaters_web/(live|views)/.*(ex)$",
      ~r"lib/heaters_web/templates/.*(eex)$",
      ~r"lib/heaters/.*(ex)$"
    ]
  ]

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Ecto query logging is disabled in the database sections above for cleaner logs
# To re-enable query logging, change `log: false` to `log: :debug` in both database configs

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
config :heaters, Oban,
  repo: Heaters.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Heaters.Pipeline.Dispatcher}
     ]}
  ],
  queues: [
    # Reduced from 10
    default: 3,
    # Reduced from 8 - only 1 concurrent video processing
    media_processing: 1,
    # Keep dispatcher and light operations
    background_jobs: 2
  ]

# Enable development-specific routes if you have them
config :heaters, dev_routes: true

# Configure PyRunner for development
# Handle Docker vs local environment for Python executable
in_docker = System.get_env("DOCKER_ENV") == "true"

python_executable =
  if in_docker do
    # In Docker container, Python is in /opt/venv
    "/opt/venv/bin/python"
  else
    # Local development, use local venv
    Path.join(Path.expand("."), "py/venv/bin/python")
  end

config :heaters, Heaters.Processing.Py.Runner,
  python_executable: python_executable,
  working_dir: if(in_docker, do: "/app", else: Path.expand(".")),
  runner_script: "py/runner.py"

# ───────────────────────────────────────────
#  S3/ExAws Configuration for Development
# ───────────────────────────────────────────
# Override base ExAws config for development-specific needs
config :ex_aws,
  access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
  secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
  region: System.get_env("AWS_REGION") || "us-west-1"

config :ex_aws, :s3,
  scheme: "https://",
  host: "s3.us-west-1.amazonaws.com",
  region: System.get_env("AWS_REGION") || "us-west-1"

# ───────────────────────────────────────────
#  CloudFront Video Streaming Configuration
# ───────────────────────────────────────────
config :heaters,
  # FFmpeg binary path for development (supports Docker and local installations)
  ffmpeg_bin:
    if(System.get_env("DOCKER_ENV") == "true",
      # Docker container path
      do: "/usr/bin/ffmpeg",
      # Local development
      else: System.get_env("FFMPEG_BIN") || "/opt/homebrew/bin/ffmpeg"
    ),
  # CloudFront distribution domain (fallback to S3 for development)
  cloudfront_domain: System.get_env("DEV_CLOUDFRONT_DOMAIN"),
  # S3 bucket configuration
  s3_dev_bucket_name: System.get_env("DEV_S3_BUCKET_NAME") || "heaters-dev",
  aws_region: System.get_env("AWS_REGION") || "us-west-1",
  # FFmpeg streaming timeout (increased for CloudFront latency)
  ffmpeg_stream_timeout: 60_000
