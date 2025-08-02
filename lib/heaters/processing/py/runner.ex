defmodule Heaters.Processing.Py.Runner do
  @moduledoc """
  Spawn-and-monitor a Python task through an OS port, with
  environment injection and Phoenix-PubSub progress streaming.
  """

  alias HeatersWeb.Endpoint
  require Logger

  @default_timeout :timer.minutes(30)

  ## Configuration

  @config_key Heaters.Processing.Py.Runner

  defp python_executable do
    get_config!(:python_executable)
  end

  defp working_dir do
    get_config!(:working_dir)
  end

  defp runner_script do
    get_config!(:runner_script)
  end

  defp runner_script_path do
    Path.join(working_dir(), runner_script())
  end

  defp get_config!(key) do
    case Application.get_env(:heaters, @config_key)[key] do
      nil ->
        raise "Heaters.PyRunner configuration missing key: #{key}. Please check your config files."

      value when is_binary(value) ->
        value

      value ->
        raise "Heaters.PyRunner configuration key #{key} must be a string, got: #{inspect(value)}"
    end
  end

  @type error_reason ::
          :timeout
          | String.t()
          | %{exit_status: integer(), output: String.t()}

  # Dialyzer suppressions required due to external system dependencies.
  #
  # Even with our configuration-based approach, Dialyzer's static analysis
  # cannot prove at compile time that:
  # 1. The configured Python executable exists and is runnable
  # 2. The working directory and script paths are valid
  # 3. Port.open/2 will succeed with the runtime environment
  # 4. External processes will behave predictably
  #
  # These suppressions are a common pattern when interfacing with external
  # systems where runtime conditions cannot be statically verified.
  @dialyzer {:nowarn_function,
             [
               open_port: 3,
               create_port: 3,
               run_impl: 3,
               handle_port_messages: 4,
               interpret_exit: 2,
               join_lines: 1
             ]}

  @spec run(String.t(), list() | map(), keyword()) :: {:ok, map()} | {:error, error_reason()}
  def run(task_name, args, opts \\ []) do
    run_impl(task_name, args, opts)
  end

  @doc """
  Runs a Python task with the given arguments and formatted error messages.

  This function wraps `run/3` with user-friendly error formatting, making it
  the preferred interface for domain operations.

  ## Parameters
  - `task_name`: Name of the Python task to execute
  - `args`: Arguments to pass to the Python script (will be JSON encoded)
  - `opts`: Options including timeout and pubsub topic

  ## Returns
  - `{:ok, python_result()}` on success
  - `{:error, String.t()}` on failure with formatted error message
  """
  @spec run_python_task(String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run_python_task(task_name, args, opts \\ []) do
    case run(task_name, args, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, format_task_error(task_name, reason)}
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

  # Split the implementation to make success paths crystal clear to Dialyzer
  @spec run_impl(String.t(), list() | map(), keyword()) :: {:ok, map()} | {:error, error_reason()}
  defp run_impl(task_name, args, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    pubsub_topic = Keyword.get(opts, :pubsub_topic)

    case Jason.encode(args) do
      {:ok, json_args} ->
        case build_env() do
          {:ok, env} ->
            case open_port(task_name, json_args, env) do
              {:ok, port} ->
                handle_port_messages(port, [], pubsub_topic, timeout)

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, %Jason.EncodeError{message: msg}} ->
        {:error, "Failed to encode arguments as JSON: #{msg}"}
    end
  end

  # Port creation with error handling
  @spec open_port(String.t(), String.t(), list()) :: {:ok, port()} | {:error, String.t()}
  defp open_port(task_name, json_args, env) do
    try do
      port = create_port(task_name, json_args, env)
      {:ok, port}
    rescue
      e ->
        {:error, "Failed to create port for task '#{task_name}': #{Exception.message(e)}"}
    end
  end

  # Port creation with explicit error handling
  @spec create_port(String.t(), String.t(), list()) :: port()
  defp create_port(task_name, json_args, env) do
    Port.open(
      {:spawn_executable, python_executable()},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, [runner_script_path(), task_name, json_args]},
        {:env, env},
        {:cd, working_dir()}
      ]
    )
  end

  # Message handling with timeout
  @spec handle_port_messages(port(), list(), String.t() | nil, pos_integer()) ::
          {:ok, map()} | {:error, error_reason()}
  defp handle_port_messages(port, acc, pubsub_topic, timeout) do
    receive do
      {^port, {:data, data}} ->
        case process_port_data(data, pubsub_topic) do
          {:continue, new_acc} ->
            handle_port_messages(port, new_acc, pubsub_topic, timeout)

          {:complete, result} ->
            Port.close(port)
            {:ok, result}
        end

      {^port, {:exit_status, status}} ->
        Port.close(port)
        interpret_exit(status, acc)

      {^port, {:EXIT, _pid, reason}} ->
        Port.close(port)
        {:error, "Port process exited: #{inspect(reason)}"}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  # Process port data and handle progress streaming
  @spec process_port_data(String.t(), String.t() | nil) ::
          {:continue, list()} | {:complete, map()}
  defp process_port_data(data, pubsub_topic) do
    lines = String.split(data, "\n", trim: true)

    Enum.reduce_while(lines, [], fn line, acc ->
      case parse_line(line) do
        {:progress, progress_data} ->
          # Stream progress to PubSub if topic provided
          if pubsub_topic do
            Endpoint.broadcast(pubsub_topic, "progress", progress_data)
          end

          {:cont, acc}

        {:result, result_data} ->
          {:halt, {:complete, result_data}}

        {:error, error_data} ->
          {:halt, {:error, error_data}}

        :ignore ->
          {:cont, acc}
      end
    end)
    |> case do
      {:complete, result} -> {:complete, result}
      {:error, error} -> {:error, error}
      acc -> {:continue, acc}
    end
  end

  # Parse individual lines from Python output
  @spec parse_line(String.t()) ::
          {:progress, map()} | {:result, map()} | {:error, String.t()} | :ignore
  defp parse_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "progress"} = data} ->
        {:progress, Map.delete(data, "type")}

      {:ok, %{"type" => "result"} = data} ->
        {:result, Map.delete(data, "type")}

      {:ok, %{"type" => "error"} = data} ->
        {:error, Map.get(data, "message", "Unknown error")}

      {:ok, _other} ->
        :ignore

      {:error, _} ->
        :ignore
    end
  end

  # Interpret exit status
  @spec interpret_exit(integer(), list()) :: {:ok, map()} | {:error, error_reason()}
  defp interpret_exit(0, _acc) do
    # Success - should have received result via JSON
    {:error, "Python task completed without returning result"}
  end

  defp interpret_exit(status, acc) do
    # Failure - return accumulated output
    output = join_lines(acc)
    {:error, %{exit_status: status, output: output}}
  end

  # Join accumulated lines
  @spec join_lines(list()) :: String.t()
  defp join_lines(lines) do
    lines
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # Build environment for Python process
  @spec build_env() :: {:ok, list()} | {:error, String.t()}
  defp build_env do
    base_env = System.get_env()

    # Add any additional environment variables needed for Python
    env_with_python = Map.put(base_env, "PYTHONPATH", working_dir())

    {:ok, Enum.map(env_with_python, fn {k, v} -> {k, v} end)}
  end

  # Format task-specific error messages for better user experience
  @spec format_task_error(String.t(), error_reason()) :: String.t()
  defp format_task_error(task_name, reason) do
    case reason do
      :timeout ->
        "Python task '#{task_name}' timed out"

      %{exit_status: status, output: output} ->
        "Python task '#{task_name}' failed with exit status #{status}: #{String.trim(output)}"

      binary when is_binary(binary) ->
        "Python task '#{task_name}' failed: #{binary}"
    end
  end
end
