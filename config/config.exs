# This file is responsible for configuring the application
# and its dependencies with the aid of the Config module.

import Config

config :heaters, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  repo: Heaters.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       # Every 60 seconds, run the Dispatcher worker
       {"* * * * *", Heaters.Pipeline.Dispatcher}
     ]}
  ],
  queues: [
    default: 10,
    # For video processing, clip processing, and edit operations
    media_processing: 5,
    # For dispatcher and archive operations
    background_jobs: 2,
    # For temporary clip generation (dev)
    temp_clips: 5,
    # For clip exports (tiny-file approach)
    exports: 5,
    # For maintenance tasks (cleanup, monitoring)
    maintenance: 1
  ]

# General application configuration
config :heaters,
  ecto_repos: [Heaters.Repo],
  generators: [timestamp_type: :utc_datetime]

# Clip delivery method configuration
config :heaters, :clip_delivery, :tiny_file

# Playback cache configuration
config :heaters, :playback_cache,
  # Maximum total cache size (1GB)
  max_cache_size_bytes: 1_000_000_000,
  # Minimum free disk space required (500MB)
  min_free_disk_bytes: 500_000_000,
  # Maximum age for temp files (15 minutes)
  max_age_minutes: 15

# Tell Ecto/Postgres about our custom types (for the `vector` column)
config :heaters, Heaters.Repo, types: Heaters.PostgresTypes

# Configures the endpoint
config :heaters, HeatersWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [html: HeatersWeb.ErrorHTML, json: HeatersWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Heaters.PubSub,
  # Replace with a secure salt from `mix phx.gen.secret 32`
  live_view: [signing_salt: "KWvQc1I2"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Suppress spitfire warnings about private Elixir macros
config :elixir, :warnings_as_errors, false
config :elixir, :ansi_enabled, true

# Configure database port
config :heaters, :repo_port, Heaters.Database.EctoAdapter

# Configure PyRunner paths and executables
config :heaters, Heaters.Processing.Support.PythonRunner,
  python_executable: System.get_env("PYTHON_EXECUTABLE") || "python3",
  working_dir: System.get_env("PYTHON_WORKING_DIR") || File.cwd!(),
  runner_script: "py/runner.py"

# Configure native splice functionality
config :heaters, :splice_config,
  monitoring: %{
    # 15 minutes
    max_processing_time_ms: 900_000,
    memory_limit_mb: 2048,
    log_performance_metrics: true
  }

# Configure ExAws for S3 operations
config :ex_aws,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :instance_role],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :instance_role],
  region: {:system, "AWS_REGION"}

config :ex_aws, :s3,
  scheme: "https://",
  host: "s3.amazonaws.com",
  region: {:system, "AWS_REGION"}

# Configure esbuild (the bundler used for JS/CSS)
config :esbuild,
  # Use the latest appropriate version
  version: "0.18.17",
  default: [
    args: ~w(
        js/app.js
        --bundle
        --target=es2022
        --outdir=../priv/static/assets
        --external:/fonts/*
        --external:/images/*
        --alias:@=.
      ),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Import environment-specific config. This must remain at the bottom
# so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
