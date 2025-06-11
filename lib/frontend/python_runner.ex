defmodule Frontend.PythonRunner do
  @moduledoc """
  Spawn-and-monitor a Python task through an OS port, with
  environment injection and Phoenix-PubSub progress streaming.
  """

  alias FrontendWeb.Endpoint
  require Logger

  @runner_script "py_tasks/runner.py"
  @default_timeout :timer.minutes(30)

  @type error_reason ::
          :timeout
          | String.t()
          | %{exit_status: integer(), output: String.t()}
          | %{reason: atom(), details: any(), output: String.t()}

  @spec run(String.t(), list() | map(), keyword()) :: {:ok, map()} | {:error, error_reason()}
  def run(task_name, args, opts \\ []) do
    timeout       = Keyword.get(opts, :timeout, @default_timeout)
    pubsub_topic  = Keyword.get(opts, :pubsub_topic)

    with {:ok, json_args}   <- Jason.encode(args),
         {:ok, env}         <- build_env(),
         {:ok, port}        <- open_port(task_name, json_args, env) do
      handle_port_messages(port, [], pubsub_topic, timeout)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # --------------------------------------------------------------------------
  # Port helpers
  # --------------------------------------------------------------------------

  defp open_port(task_name, json_args, env) do
    python_exe = py_executable()

    # Write JSON args to a temporary file to avoid shell escaping issues
    tmp_file = "/tmp/python_args_#{:rand.uniform(1000000)}.json"
    case File.write(tmp_file, json_args) do
      :ok ->
        args = [task_name, "--args-file", tmp_file]

        port =
          Port.open(
            {:spawn_executable, python_exe},
            [
              :binary,
              :exit_status,
              :hide,
              {:packet, :line},
              {:args, ["py_tasks/runner.py" | args]},
              {:env, env},
              {:cd, "/app"}
            ]
          )

        Port.monitor(port)
        {:ok, port}

      {:error, reason} ->
        {:error, "Failed to write temp file: #{reason}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # --------------------------------------------------------------------------
  # Environment builder
  # --------------------------------------------------------------------------

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
        Logger.error("PythonRunner: Failed to build environment: #{reason}")
        {:error, reason}
    end
  end

  defp fetch_env(var) do
    case System.get_env(var) do
      nil -> {:error, "Environment variable #{var} not set"}
      val -> {:ok, val}
    end
  end

  defp db_url_var("production"),  do: "PROD_DATABASE_URL"
  defp db_url_var(_),             do: "DEV_DATABASE_URL"
  defp s3_bucket_var("production"),do: "S3_PROD_BUCKET_NAME"
  defp s3_bucket_var(_),           do: "S3_DEV_BUCKET_NAME"

  # --------------------------------------------------------------------------
  # Port loop
  # --------------------------------------------------------------------------

  @spec handle_port_messages(port(), [String.t()], String.t() | nil, timeout()) ::
          {:ok, map()} | {:error, error_reason()}
  defp handle_port_messages(port, buffer, pubsub_topic, timeout) do
    receive do
      {^port, {:data, line}} ->
        trimmed = String.trim(line)
        Logger.info("[python] " <> trimmed)
        if pubsub_topic, do: Endpoint.broadcast(pubsub_topic, "progress", %{line: trimmed})
        handle_port_messages(port, [trimmed | buffer], pubsub_topic, timeout)

      {^port, {:exit_status, status}} ->
        Port.close(port)
        # Log all output on non-zero exit for debugging
        if status != 0 do
          output = join_lines(buffer)
          Logger.error("PythonRunner: Process exited with status #{status}")
          Logger.error("PythonRunner: Full output: #{output}")
        end
        interpret_exit(status, buffer)

      {:DOWN, _ref, :port, ^port, reason} ->
        Port.close(port)
        Logger.error("PythonRunner: Port died with reason: #{inspect(reason)}")
        {:error, %{reason: :port_died, details: reason, output: join_lines(buffer)}}

      _other ->
        handle_port_messages(port, buffer, pubsub_topic, timeout)
    after
      timeout ->
        Port.close(port)
        Logger.error("PythonRunner: Process timed out after #{timeout}ms")
        {:error, :timeout}
    end
  end

  # --------------------------------------------------------------------------
  # Exit interpretation
  # --------------------------------------------------------------------------

  defp interpret_exit(0, buffer) do
    case extract_final_json(buffer) do
      {:ok, payload} -> {:ok, payload}
      :no_json       -> {:ok, %{"status" => "success"}}
      {:error, err}  -> {:error, err}
    end
  end

  defp interpret_exit(status, buffer) do
    output = join_lines(buffer)
    Logger.error("PythonRunner: Process exited with status #{status}")
    {:error, %{exit_status: status, output: output}}
  end

  defp extract_final_json(lines) do
    case Enum.find(lines, &String.starts_with?(&1, "FINAL_JSON:")) do
      nil ->
        :no_json

      "FINAL_JSON:" <> json ->
        json = String.trim(json)

        case Jason.decode(json) do
          {:ok, decoded}   -> {:ok, decoded}
          {:error, reason} ->
            {:error, %{reason: :json_decode_error, details: reason, output: join_lines(lines)}}
        end
    end
  end

  defp join_lines(lines), do: lines |> Enum.reverse() |> Enum.join("\n")

  # --------------------------------------------------------------------------
  # Helper functions
  # --------------------------------------------------------------------------

  defp py_executable do
    System.find_executable("python3") || "python3"
  end
end
