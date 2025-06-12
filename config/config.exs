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
       {"* * * * *", Heaters.Workers.Dispatcher}
     ]}
  ],
  queues: [
    default: 10,
    # For video processing
    ingest: 3,
    # Added missing queue for most workers
    media_processing: 5,
    # Added missing queue for dispatcher/archive
    background_jobs: 2,
    # Renamed from 'embed' to match worker usage
    embeddings: 2
  ]

# General application configuration
config :heaters,
  ecto_repos: [Heaters.Repo],
  generators: [timestamp_type: :utc_datetime]

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

# Configure PythonRunner paths and executables
config :heaters, Heaters.PythonRunner,
  python_executable: System.get_env("PYTHON_EXECUTABLE") || "python3",
  working_dir: System.get_env("PYTHON_WORKING_DIR") || File.cwd!(),
  runner_script: "python/runner.py"

# Configure esbuild (the bundler used for JS/CSS)
config :esbuild,
  # Use the latest appropriate version
  version: "0.18.17",
  default: [
    args: ~w(
        js/app.js
        --bundle
        --target=es2017
        --outdir=../priv/static/assets
        --external:/fonts/*
        --external:/images/*
      ),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Import environment-specific config. This must remain at the bottom
# so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
