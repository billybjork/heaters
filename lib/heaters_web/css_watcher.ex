defmodule HeatersWeb.CSSWatcher do
  @moduledoc """
  Custom CSS watcher that runs PostCSS in watch mode for hot reloading.
  """

  def install_and_run do
    install_and_run("css", [])
  end

  def install_and_run(_name, _args) do
    assets_path = Path.expand("../assets", __DIR__)
    cmd = "npx"
    cmd_args = ["postcss", "css/app.css", "-o", "../priv/static/assets/app.css", "--watch"]

    System.cmd(cmd, cmd_args, cd: assets_path, into: IO.stream(:stdio, :line))
  end
end
