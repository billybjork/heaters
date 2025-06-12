defmodule Heaters.Release do
  # This should match your OTP app name in mix.exs
  @app :heaters

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  def migrate do
    IO.puts("Running Ecto migrations for production...")
    # Ensure the Repo is started if not already by the release boot process
    # For releases, the app is typically started, so Repo should be too.
    # If not, you might need:
    # for repo_module <- repos() do
    #   {:ok, _pid} = repo_module.start_link(pool_size: 2) # Temporary link for migration
    # end

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    IO.puts("Ecto migrations complete for production.")
  end

  # Optional: Seeding for production (use with caution)
  # def seed do
  #   IO.puts("Seeding database for production...")
  #   # Ensure Heaters.Repo is started or passed if needed
  #   Code.require_file("priv/repo/seeds.exs", __DIR__) # Make sure seeds.exs is prod-safe
  #   IO.puts("Database seeding complete for production.")
  # end
end
