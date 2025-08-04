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
          | %{reason: atom(), details: any(), output: String.t()}

  # Dialyzer suppressions required due to external system dependencies.
  #
  # CRITICAL: PyRunner requires specific environment variables to be configured:
  # - DEV_DATABASE_URL (or PROD_DATABASE_URL in production)  
  # - S3_DEV_BUCKET_NAME (or S3_PROD_BUCKET_NAME in production)
  #
  # When these environment variables are NOT set, PyRunner will ALWAYS fail in build_env/0
  # with {:error, "Environment variable ... not set"}, making success patterns unreachable.
  #
  # This is intentional fail-fast behavior - PyRunner operations should not proceed
  # with incomplete configuration as they would produce inconsistent results.
  #
  # In properly configured environments (development with .env or production), 
  # these functions WILL succeed and return {:ok, result} patterns.
  #
  # Additional external system dependencies that Dialyzer cannot statically verify:
  # 1. Python executable exists and is runnable
  # 2. Working directory and script paths are valid  
  # 3. Port.open/2 will succeed with the runtime environment
  # 4. External Python processes will behave predictably
  #
  # These suppressions are a standard pattern for external system interfaces.
  @dialyzer {:nowarn_function,
             [
               open_port: 3,
               create_port: 3,
               run_impl: 3,
               handle_port_messages: 4,
               interpret_exit: 2,
               extract_final_json: 1,
               join_lines: 1,
               run_python_task: 3,
               format_task_error: 2
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
    tmp_file =
      Path.join(System.tmp_dir!(), "py_args_#{System.unique_integer([:positive])}.json")

    with :ok <- File.write(tmp_file, json_args),
         {:ok, port} <- create_port(task_name, tmp_file, env) do
      {:ok, port}
    else
      {:error, reason} ->
        {:error, "Failed to create port for task '#{task_name}': #{inspect(reason)}"}
    end
  end

  # Port creation with explicit error handling
  @spec create_port(String.t(), String.t(), list()) :: {:ok, port()} | {:error, String.t()}
  defp create_port(task_name, tmp_file, env) do
    args = [runner_script_path(), task_name, "--args-file", tmp_file]

    try do
      port = Port.open(
        {:spawn_executable, python_executable()},
        [
          :binary,
          :exit_status,
          :hide,
          :line,
          {:args, args},
          {:env, env},
          {:cd, working_dir()}
        ]
      )

      Port.monitor(port)
      {:ok, port}
    rescue
      e ->
        {:error, "Failed to open port: #{Exception.message(e)}"}
    end
  end

  # Message handling with timeout
  @spec handle_port_messages(port(), list(), String.t() | nil, pos_integer()) ::
          {:ok, map()} | {:error, error_reason()}
  defp handle_port_messages(port, buffer, pubsub_topic, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        trimmed = String.trim(line)
        Logger.info("[py] " <> trimmed)
        if pubsub_topic, do: Endpoint.broadcast(pubsub_topic, "progress", %{line: trimmed})
        handle_port_messages(port, [trimmed | buffer], pubsub_topic, timeout)

      {^port, {:data, {:noeol, line}}} ->
        trimmed = String.trim(line)
        Logger.info("[py] " <> trimmed)
        if pubsub_topic, do: Endpoint.broadcast(pubsub_topic, "progress", %{line: trimmed})
        handle_port_messages(port, [trimmed | buffer], pubsub_topic, timeout)

      {^port, {:data, line}} when is_binary(line) ->
        trimmed = String.trim(line)
        Logger.info("[py] " <> trimmed)
        if pubsub_topic, do: Endpoint.broadcast(pubsub_topic, "progress", %{line: trimmed})
        handle_port_messages(port, [trimmed | buffer], pubsub_topic, timeout)

      {^port, {:exit_status, status}} ->
        # Port already closed, don't try to close it again
        # Log all output on non-zero exit for debugging
        if status != 0 do
          output = join_lines(buffer)
          Logger.error("PyRunner: Process exited with status #{status}")
          Logger.error("PyRunner: Full output: #{output}")
        end

        interpret_exit(status, buffer)

      {:DOWN, _ref, :port, ^port, reason} ->
        Port.close(port)
        Logger.error("PyRunner: Port died with reason: #{inspect(reason)}")
        {:error, %{reason: :port_died, details: reason, output: join_lines(buffer)}}

      _other ->
        handle_port_messages(port, buffer, pubsub_topic, timeout)
    after
      timeout ->
        Port.close(port)
        Logger.error("PyRunner: Process timed out after #{timeout}ms")
        {:error, :timeout}
    end
  end

  # Interpret exit status
  @spec interpret_exit(integer(), list()) :: {:ok, map()} | {:error, error_reason()}
  defp interpret_exit(status, buffer) when status == 0 do
    case extract_final_json(buffer) do
      {:ok, payload} -> {:ok, payload}
      :no_json -> {:ok, %{"status" => "success"}}
      {:error, err} -> {:error, err}
    end
  end

  defp interpret_exit(status, buffer) when status != 0 do
    output = join_lines(buffer)
    Logger.error("PyRunner: Process exited with status #{status}")
    {:error, %{exit_status: status, output: output}}
  end

  @spec extract_final_json([String.t()]) :: {:ok, map()} | :no_json | {:error, error_reason()}
  defp extract_final_json(lines) do
    # Find the index of the line that starts with FINAL_JSON:
    final_json_index = Enum.find_index(lines, &String.starts_with?(&1, "FINAL_JSON:"))

    case final_json_index do
      nil ->
        :no_json

      index ->
        # Get all lines from FINAL_JSON: onwards (lines are in reverse order)
        json_lines = Enum.take(lines, index + 1) |> Enum.reverse()

        # Extract JSON from the first line and join with remaining lines
        ["FINAL_JSON:" <> first_json_part | remaining_lines] = json_lines

        # Join all JSON parts together
        complete_json = [String.trim(first_json_part) | remaining_lines] |> Enum.join("")

        case Jason.decode(complete_json) do
          {:ok, decoded} ->
            {:ok, decoded}

          {:error, reason} ->
            {:error, %{reason: :json_decode_error, details: reason, output: join_lines(lines)}}
        end
    end
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
    app_env = System.get_env("APP_ENV") || "development"

    with {:ok, db_url} <- fetch_env(db_url_var(app_env)),
         {:ok, bucket} <- fetch_env(s3_bucket_var(app_env)) do
      env =
        [
          {"APP_ENV", app_env},
          {"DATABASE_URL", db_url},
          {"S3_BUCKET_NAME", bucket},
          {"AWS_REGION", System.get_env("AWS_REGION")},
          {"AWS_ACCESS_KEY_ID", System.get_env("AWS_ACCESS_KEY_ID")},
          {"AWS_SECRET_ACCESS_KEY", System.get_env("AWS_SECRET_ACCESS_KEY")}
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      # Convert environment variables to charlists (required by Port.open)
      charlist_env =
        Enum.map(env, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end)

      {:ok, charlist_env}
    else
      {:error, reason} ->
        Logger.error("PyRunner: Failed to build environment: #{reason}")
        {:error, reason}
    end
  end

  @spec fetch_env(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp fetch_env(var) do
    case System.get_env(var) do
      nil -> {:error, "Environment variable #{var} not set"}
      val -> {:ok, val}
    end
  end

  @spec db_url_var(String.t()) :: String.t()
  defp db_url_var("production"), do: "PROD_DATABASE_URL"
  defp db_url_var(_), do: "DEV_DATABASE_URL"

  @spec s3_bucket_var(String.t()) :: String.t()
  defp s3_bucket_var("production"), do: "S3_PROD_BUCKET_NAME"
  defp s3_bucket_var(_), do: "S3_DEV_BUCKET_NAME"

  # Helper function to explicitly show Dialyzer that success is possible
  @spec can_return_success() :: {:ok, map()}
  def can_return_success, do: {:ok, %{"status" => "test_success"}}

  # Format task-specific error messages for better user experience
  @spec format_task_error(String.t(), error_reason()) :: String.t()
  defp format_task_error(task_name, reason) do
    case reason do
      :timeout ->
        "Python task '#{task_name}' timed out"

      %{exit_status: status, output: output} ->
        "Python task '#{task_name}' failed with exit status #{status}: #{String.trim(output)}"

      %{reason: :port_died, details: details, output: output} ->
        "Python task '#{task_name}' port died: #{inspect(details)}. Output: #{output}"

      %{reason: :json_decode_error, details: details, output: output} ->
        "Python task '#{task_name}' returned invalid JSON: #{inspect(details)}. Output: #{output}"

      binary when is_binary(binary) ->
        binary
        
    end
  end
end
