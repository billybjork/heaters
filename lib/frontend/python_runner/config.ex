defmodule Frontend.PythonRunner.Config do
  @moduledoc """
  Centralized configuration for Python script execution.
  Handles environment-specific paths with runtime safety.
  """

  @app :frontend
  @key Frontend.PythonRunner

  @doc """
  Returns the configured Python executable path.
  Uses runtime configuration access to prevent Dialyzer constant folding.
  """
  @spec python_executable() :: String.t()
  def python_executable do
    get_config()[:python_executable]
  end

  @doc """
  Returns the configured working directory path.
  Uses runtime configuration access to prevent Dialyzer constant folding.
  """
  @spec working_dir() :: String.t()
  def working_dir do
    get_config()[:working_dir]
  end

  @doc """
  Returns the configured runner script path relative to working_dir.
  """
  @spec runner_script() :: String.t()
  def runner_script do
    get_config()[:runner_script]
  end

  @doc """
  Returns the full path to the runner script.
  """
  @spec runner_script_path() :: String.t()
  def runner_script_path do
    Path.join(working_dir(), runner_script())
  end

  # Private function to get config at runtime, preventing Dialyzer constant folding
  @spec get_config() :: map()
  defp get_config do
    # Use apply/3 to hide from Dialyzer's constant folding
    apply(Application, :get_env, [@app, @key, []])
    |> Map.new()
  end
end
