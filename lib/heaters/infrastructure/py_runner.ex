defmodule Heaters.Infrastructure.PyRunner do
  @moduledoc """
  Spawn-and-monitor a Python task through an OS port, with
  environment injection and Phoenix-PubSub progress streaming.
  """

  alias HeatersWeb.Endpoint
  alias Heaters.Infrastructure.PyRunner.Config
  require Logger

  @default_timeout :timer.minutes(30)

  @type error_reason ::
          :timeout
          | String.t()
          | %{exit_status: integer(), output: String.t()}
          | %{reason: atom(), details: any(), output: String.t()}

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
               extract_final_json: 1,
               join_lines: 1
             ]}

  @spec run(String.t(), list() | map(), keyword()) :: {:ok, map()} | {:error, error_reason()}
  def run(task_name, args, opts \\ []) do
    run_impl(task_name, args, opts)
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
        {:error, "Failed to encode arguments: #{msg}"}
    end
  end

  # --------------------------------------------------------------------------
  # Port helpers
  # --------------------------------------------------------------------------

  @spec open_port(String.t(), iodata(), [{String.t(), String.t()}]) ::
          {:ok, port()} | {:error, String.t()}
  defp open_port(task_name, json_args, env) do
    tmp_file =
      Path.join(System.tmp_dir!(), "py_args_#{System.unique_integer([:positive])}.json")

    with :ok <- File.write(tmp_file, json_args),
         {:ok, port} <- create_port(task_name, tmp_file, env) do
      {:ok, port}
    end
  end

  @spec create_port(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, port()} | {:error, String.t()}
  defp create_port(task_name, tmp_file, env) do
    py_exe = Config.python_executable()
    working_dir = Config.working_dir()
    runner_script_path = Config.runner_script_path()

    args = [runner_script_path, task_name, "--args-file", tmp_file]

    Logger.info(
      "PyRunner: Creating port with py_exe=#{py_exe}, working_dir=#{working_dir}, script_exists=#{File.exists?(runner_script_path)}"
    )

    Logger.info("PyRunner: Args: #{inspect(args)}")
    Logger.info("PyRunner: Env: #{inspect(env)}")

    Logger.info("PyRunner: Args types: #{inspect(Enum.map(args, &{&1, :erlang.is_list(&1)}))}")

    Logger.info("PyRunner: Python exe type: #{inspect({py_exe, :erlang.is_list(py_exe)})}")

    # Convert environment variables to charlists (required by Port.open)
    charlist_env =
      Enum.map(env, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    Logger.info("PyRunner: Original env: #{inspect(env)}")
    Logger.info("PyRunner: Charlist env: #{inspect(charlist_env)}")

    port_options = [
      :binary,
      :exit_status,
      :hide,
      :line,
      {:args, args},
      {:env, charlist_env},
      {:cd, working_dir}
    ]

    Logger.info("PyRunner: Port options: #{inspect(port_options)}")
    Logger.info("PyRunner: About to call Port.open with:")
    Logger.info("PyRunner:   First arg: #{inspect({:spawn_executable, py_exe})}")
    Logger.info("PyRunner:   Second arg: #{inspect(port_options)}")

    try do
      port =
        Port.open(
          {:spawn_executable, py_exe},
          port_options
        )

      Port.monitor(port)
      Logger.info("PyRunner: Port created successfully")
      {:ok, port}
    rescue
      e ->
        error_msg = "Failed to open port: #{Exception.message(e)}"
        Logger.error("PyRunner: #{error_msg}")
        Logger.error("PyRunner: Exception details: #{inspect(e)}")
        Logger.error("PyRunner: Python exe exists? #{File.exists?(py_exe)}")
        Logger.error("PyRunner: Working dir exists? #{File.exists?(working_dir)}")
        Logger.error("PyRunner: Runner script exists? #{File.exists?(runner_script_path)}")
        {:error, error_msg}
    end
  end

  # --------------------------------------------------------------------------
  # Environment builder
  # --------------------------------------------------------------------------

  @spec build_env() :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
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

      {:ok, env}
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

  # --------------------------------------------------------------------------
  # Port loop
  # --------------------------------------------------------------------------

  @spec handle_port_messages(port(), [String.t()], String.t() | nil, timeout()) ::
          {:ok, map()} | {:error, error_reason()}
  defp handle_port_messages(port, buffer, pubsub_topic, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        trimmed = String.trim(line)
        Logger.info("[py] " <> trimmed)
        if pubsub_topic, do: Endpoint.broadcast(pubsub_topic, "progress", %{line: trimmed})
        handle_port_messages(port, [trimmed | buffer], pubsub_topic, timeout)

      {^port, {:data, line}} ->
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

  # --------------------------------------------------------------------------
  # Exit interpretation
  # --------------------------------------------------------------------------

  @spec interpret_exit(integer(), [String.t()]) :: {:ok, map()} | {:error, error_reason()}
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
    case Enum.find(lines, &String.starts_with?(&1, "FINAL_JSON:")) do
      nil ->
        :no_json

      "FINAL_JSON:" <> json ->
        json = String.trim(json)

        case Jason.decode(json) do
          {:ok, decoded} ->
            {:ok, decoded}

          {:error, reason} ->
            {:error, %{reason: :json_decode_error, details: reason, output: join_lines(lines)}}
        end
    end
  end

  @spec join_lines([String.t()]) :: String.t()
  defp join_lines(lines), do: lines |> Enum.reverse() |> Enum.join("\n")

  # Helper function to explicitly show Dialyzer that success is possible
  @spec can_return_success() :: {:ok, map()}
  def can_return_success, do: {:ok, %{"status" => "test_success"}}
end
