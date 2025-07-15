defmodule Heaters.Infrastructure.Adapters.PyRunnerAdapter do
  @moduledoc """
  PyRunner adapter providing consistent I/O interface for domain operations.
  Wraps Infrastructure.PyRunner with standardized error handling.
  """

  alias Heaters.Infrastructure.PyRunner

  @type python_result :: %{
          String.t() => any()
        }

  @type run_options :: [
          timeout: pos_integer(),
          pubsub_topic: String.t() | nil
        ]

  @doc """
  Runs a Python task with the given arguments.

  ## Parameters
  - `task_name`: Name of the Python task to execute
  - `args`: Arguments to pass to the Python script (will be JSON encoded)
  - `opts`: Options including timeout and pubsub topic

  ## Returns
  - `{:ok, python_result()}` on success
  - `{:error, String.t()}` on failure with formatted error message
  """
  @spec run_python_task(String.t(), map(), run_options()) ::
          {:ok, python_result()} | {:error, String.t()}
  def run_python_task(task_name, args, opts \\ []) do
    case PyRunner.run(task_name, args, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, format_python_error(task_name, reason)}
    end
  end


  @doc """
  Checks if the Python runner environment is properly configured.

  ## Returns
  - `:ok` if environment is ready
  - `{:error, String.t()}` if configuration issues exist
  """
  @spec validate_python_environment() :: :ok | {:error, String.t()}
  def validate_python_environment do
    # This could be expanded to check Python executable, working directory, etc.
    :ok
  end

  ## Private helper functions

  @spec format_python_error(String.t(), any()) :: String.t()
  defp format_python_error(task_name, reason) do
    case reason do
      :timeout ->
        "Python task '#{task_name}' timed out"

      %{exit_status: status, output: output} ->
        "Python task '#{task_name}' failed with exit status #{status}: #{String.trim(output)}"

      %{reason: atom_reason, details: details, output: output} when is_atom(atom_reason) ->
        "Python task '#{task_name}' failed: #{atom_reason} - #{inspect(details)} (output: #{String.trim(output)})"

      binary when is_binary(binary) ->
        "Python task '#{task_name}' failed: #{binary}"

      other ->
        "Python task '#{task_name}' failed with unknown error: #{inspect(other)}"
    end
  end
end
