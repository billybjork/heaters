ExUnit.start()

# Ensure the test database is set up
Ecto.Adapters.SQL.Sandbox.mode(Heaters.Repo, :manual)
