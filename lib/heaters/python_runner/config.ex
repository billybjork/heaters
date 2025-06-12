defmodule Heaters.PythonRunner.Config do
  @moduledoc """
  Centralized configuration for Python script execution.
  Handles environment-specific paths with runtime safety.
  """

  @app :heaters
  @key Heaters.PythonRunner

  @doc """
  Returns the configured Python executable path.
  Uses runtime configuration access to prevent Dialyzer constant folding.
  """
  @spec python_executable() :: String.t()
  def python_executable do
    get_config(:python_executable)
  end

  @doc """
  Returns the configured working directory path.
  Uses runtime configuration access to prevent Dialyzer constant folding.
  """
  @spec working_dir() :: String.t()
  def working_dir do
    get_config(:working_dir)
  end

  @doc """
  Returns the configured runner script path relative to working_dir.
  """
  @spec runner_script() :: String.t()
  def runner_script do
    get_config(:runner_script)
  end

  @doc """
  Returns the full path to the runner script.
  """
  @spec runner_script_path() :: String.t()
  def runner_script_path do
    Path.join(working_dir(), runner_script())
  end

  # Private function to get specific config value at runtime, preventing Dialyzer constant folding
  @spec get_config(atom()) :: String.t()
  defp get_config(key) do
    # Use apply/3 to hide from Dialyzer's constant folding
    config = apply(Application, :get_env, [@app, @key, []])

    case Keyword.get(config, key) do
      nil ->
        raise "Heaters.PythonRunner configuration missing key: #{key}. Please check your config files."

      value when is_binary(value) ->
        value

      value ->
        raise "Heaters.PythonRunner configuration key #{key} must be a string, got: #{inspect(value)}"
    end
  end
end
