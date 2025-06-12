import Config
config :heaters, Oban, testing: :manual

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :heaters, Heaters.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "heaters_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

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

# Configure PythonRunner for testing
config :heaters, Heaters.PythonRunner,
  python_executable: "/usr/bin/env python3",
  working_dir: System.tmp_dir!(),
  runner_script: "test/fixtures/mock_runner.py"
