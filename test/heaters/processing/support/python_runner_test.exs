defmodule Heaters.Processing.Support.PythonRunnerTest do
  use ExUnit.Case, async: false

  alias Heaters.Processing.Support.PythonRunner

  @config_key Heaters.Processing.Support.PythonRunner

  setup do
    original_runner_config = Application.get_env(:heaters, @config_key)
    original_database_url = System.get_env("DATABASE_URL")
    original_s3_bucket = System.get_env("S3_BUCKET_NAME")

    Application.put_env(:heaters, @config_key,
      python_executable: "/bin/sh",
      working_dir: File.cwd!(),
      runner_script: "test/fixtures/mock_runner.sh"
    )

    System.put_env("DATABASE_URL", "ecto://test:test@localhost/heaters_test")
    System.put_env("S3_BUCKET_NAME", "heaters-test-bucket")

    on_exit(fn ->
      restore_runner_config(original_runner_config)
      restore_env("DATABASE_URL", original_database_url)
      restore_env("S3_BUCKET_NAME", original_s3_bucket)
    end)

    :ok
  end

  test "returns decoded result on success and cleans temp files" do
    before_snapshot = temp_file_snapshot()

    assert {:ok, %{"status" => "ok", "task" => "success_json"}} =
             PythonRunner.run("success_json", %{clip_id: 123})

    assert_temp_files_unchanged(before_snapshot)
  end

  test "returns explicit missing-result-file error instead of success" do
    assert {:error, %{reason: :missing_result_file, details: path, output: output}} =
             PythonRunner.run("missing_result", %{})

    assert Path.basename(path) =~ "py_result_"
    assert output =~ "intentionally not writing result file"
  end

  test "includes captured output when result JSON is malformed" do
    assert {:error, %{reason: :json_decode_error, output: output}} =
             PythonRunner.run("invalid_json", %{})

    assert output =~ "writing malformed json"
  end

  test "run_python_task formats missing-result-file errors without crashing" do
    assert {:error, message} = PythonRunner.run_python_task("missing_result", %{})
    assert message =~ "produced no result file"
  end

  test "cleans temp files on non-zero exit" do
    before_snapshot = temp_file_snapshot()

    assert {:error, %{exit_status: 1, output: output}} = PythonRunner.run("failure", %{})
    assert output =~ "failing task output line"

    assert_temp_files_unchanged(before_snapshot)
  end

  test "cleans temp files when task times out" do
    before_snapshot = temp_file_snapshot()

    assert {:error, :timeout} = PythonRunner.run("sleep_timeout", %{}, timeout: 10)

    assert_temp_files_unchanged(before_snapshot)
  end

  defp temp_file_snapshot do
    %{
      args: System.tmp_dir!() |> Path.join("py_args_*.json") |> Path.wildcard() |> MapSet.new(),
      result:
        System.tmp_dir!() |> Path.join("py_result_*.json") |> Path.wildcard() |> MapSet.new()
    }
  end

  defp assert_temp_files_unchanged(before_snapshot) do
    assert temp_file_snapshot() == before_snapshot
  end

  defp restore_runner_config(nil), do: Application.delete_env(:heaters, @config_key)
  defp restore_runner_config(config), do: Application.put_env(:heaters, @config_key, config)

  defp restore_env(key, nil), do: System.delete_env(key)

  defp restore_env(key, value) when is_binary(value) do
    System.put_env(key, value)
  end
end
