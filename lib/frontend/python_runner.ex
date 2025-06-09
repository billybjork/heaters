defmodule Frontend.PythonRunner do
  alias FrontendWeb.Endpoint # FIX: Alias the Endpoint to correctly access PubSub
  require Logger

  @py_executable "python3"
  @runner_script "py_tasks/runner.py"

  @doc """
  Runs a Python task via an OS port, providing environment-specific configuration.

  ## Options

    * `:timeout` - The maximum time to wait for the Python script to finish, in milliseconds.
      Defaults to 30 minutes.
    * `:pubsub_topic` - A string topic to broadcast progress updates to via Phoenix PubSub.
      Example: "intake_progress:" <> to_string(source_video_id)

  """
  @spec run(String.t(), list() | map(), list()) :: {:ok, map()} | {:error, :timeout | String.t()}
  def run(task_name, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(30))
    pubsub_topic = Keyword.get(opts, :pubsub_topic)
    current_app_env = app_env()

    with {:ok, json_args} <- Jason.encode(args),
         {:ok, database_url} <- fetch_env(db_url_var(current_app_env)),
         {:ok, s3_bucket_name} <- fetch_env(s3_bucket_var(current_app_env)) do
      port_env = build_env(current_app_env, database_url, s3_bucket_name)

      port =
        Port.open({:spawn_executable, @py_executable}, port_options(task_name, json_args, port_env))

      handle_port_messages(port, [], pubsub_topic, timeout)
    else
      {:error, %Jason.EncodeError{} = reason} ->
        {:error, "Invalid arguments for JSON encoding: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp app_env, do: System.get_env("APP_ENV") || "development"

  defp db_url_var("production"), do: "PROD_DATABASE_URL"
  defp db_url_var(_), do: "DEV_DATABASE_URL"

  defp s3_bucket_var("production"), do: "S3_PROD_BUCKET_NAME"
  defp s3_bucket_var(_), do: "S3_DEV_BUCKET_NAME"

  defp fetch_env(var) do
    case System.get_env(var) do
      nil -> {:error, "Environment variable #{var} not set"}
      value -> {:ok, value}
    end
  end

  defp build_env(app_env, database_url, s3_bucket_name) do
    [
      {"APP_ENV", app_env},
      {"DATABASE_URL", database_url},
      {"S3_BUCKET_NAME", s3_bucket_name},
      {"AWS_REGION", System.get_env("AWS_REGION")},
      {"AWS_ACCESS_KEY_ID", System.get_env("AWS_ACCESS_KEY_ID")},
      {"AWS_SECRET_ACCESS_KEY", System.get_env("AWS_SECRET_ACCESS_KEY")}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
  end

  defp port_options(task_name, json_args, port_env) do
    [
      :binary,
      :exit_status,
      :stream,
      :hide,
      {:args, [@runner_script, task_name, "--args-json", json_args]},
      {:env, port_env}
    ]
  end

  # This recursive loop captures all output from the Python script.
  @spec handle_port_messages(port(), list(), String.t() | nil, timeout()) ::
          {:ok, map()} | {:error, :timeout | String.t()}
  defp handle_port_messages(port, buffer, pubsub_topic, timeout) do
    receive do
      # Handles one line of output from Python's logging/print
      {^port, {:data, {:eol, line}}} ->
        # Optional: For future use with LiveView progress bars
        # FIX: Use the aliased Endpoint to correctly call broadcast/3
        Logger.info("[python] " <> line)
        if pubsub_topic, do: Endpoint.broadcast(pubsub_topic, "progress", %{line: line})
        handle_port_messages(port, [line | buffer], pubsub_topic, timeout)

      # Python script exited cleanly (exit code 0)
      {^port, {:exit_status, 0}} ->
        full_output = buffer |> Enum.reverse() |> IO.iodata_to_binary()
        # The last non-empty line of output should be the final JSON result.
        final_json = Enum.find_value(String.split(full_output, "\n", trim: true), &(&1 != ""))

        case final_json do
          nil ->
            {:ok, %{"status" => "success", "result" => "Process finished without output."}}

          json_string ->
            case Jason.decode(json_string) do
              {:ok, result} ->
                {:ok, result}

              # Handle cases where the script succeeds but has no valid JSON output.
              {:error, _} ->
                {:ok, %{"status" => "success", "result" => "Process finished without valid JSON."}}
            end
        end

      # Python script failed (non-zero exit code)
      {^port, {:exit_status, status}} ->
        full_output = buffer |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, "Python script exited with status #{status}. Output: #{full_output}"}

      # Handle any other unexpected messages
      _other ->
        handle_port_messages(port, buffer, pubsub_topic, timeout)
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end
end
