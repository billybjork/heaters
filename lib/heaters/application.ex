defmodule Heaters.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Clean up any orphaned temporary files from previous runs
    cleanup_orphaned_temp_files()

    children = [
      HeatersWeb.Telemetry,
      Heaters.Repo,
      {DNSCluster, query: Application.get_env(:heaters, :dns_cluster_query) || :ignore},
      {Oban, Application.fetch_env!(:heaters, Oban)},
      {Phoenix.PubSub, name: Heaters.PubSub},
      # FFmpeg process pool removed - using nginx MP4 dynamic clipping
      # Start a worker by calling: Heaters.Worker.start_link(arg)
      # {Heaters.Worker, arg},
      # Start to serve requests, typically the last entry
      HeatersWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Heaters.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HeatersWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Private helper for startup cleanup
  defp cleanup_orphaned_temp_files() do
    case Heaters.Storage.TempManager.cleanup_orphaned_temp_files() do
      {:ok, 0} ->
        Logger.debug("Application startup: No orphaned temp files found")

      {:ok, count} ->
        Logger.info("Application startup: Cleaned up #{count} orphaned temp directories")

      {:error, reason} ->
        Logger.warning(
          "Application startup: Failed to cleanup orphaned temp files: #{inspect(reason)}"
        )
    end
  end
end
