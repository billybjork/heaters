defmodule Heaters.Infrastructure.PyRunner.Config do
  @moduledoc """
  Configuration for PyRunner module.
  """

  @key Heaters.Infrastructure.PyRunner

  def python_executable do
    get_config!(:python_executable)
  end

  def working_dir do
    get_config!(:working_dir)
  end

  def runner_script do
    get_config!(:runner_script)
  end

  def runner_script_path do
    Path.join(working_dir(), runner_script())
  end

  defp get_config!(key) do
    case Application.get_env(:heaters, @key)[key] do
      nil ->
        raise "Heaters.PyRunner configuration missing key: #{key}. Please check your config files."

      value when is_binary(value) ->
        value

      value ->
        raise "Heaters.PyRunner configuration key #{key} must be a string, got: #{inspect(value)}"
    end
  end
end
