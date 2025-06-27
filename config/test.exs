import Config

# ───────────────────────────────────────────
#  Test Environment Configuration
# ───────────────────────────────────────────

# Disable Oban job processing during tests
config :heaters, Oban, testing: :manual

# Configure test database
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :heaters, Heaters.Repo,
  username: System.get_env("TEST_DB_USER") || "postgres",
  password: System.get_env("TEST_DB_PASSWORD") || "postgres",
  hostname: System.get_env("TEST_DB_HOST") || "localhost",
  port: String.to_integer(System.get_env("TEST_DB_PORT") || "5432"),
  database: (System.get_env("TEST_DB_NAME") || "heaters_test") <> "#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # Improve test performance
  ownership_timeout: 60_000,
  timeout: 30_000,
  queue_target: 1000,
  queue_interval: 1000,
  # Ensure clean state for each test
  prepare: :named,
  # Use UTC for consistency
  show_sensitive_data_on_connection_error: true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :heaters, HeatersWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "x6pNY/nuDeT1piDTFtTzrGzDTOe17WxwcvqPUVmUZoI57DpfzMl9FIJr/hDnBI2Z",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Configure PyRunner for testing
config :heaters, Heaters.Infrastructure.PyRunner,
  python_executable: "/usr/bin/env python3",
  working_dir: System.tmp_dir!(),
  runner_script: "test/fixtures/mock_runner.py"

# Configure S3/CloudFront for testing (minimal stubs)
config :heaters, :app_env, "test"
config :heaters, :cloudfront_domain, "test.cloudfront.test"
config :heaters, :s3_bucket, "test-bucket"
