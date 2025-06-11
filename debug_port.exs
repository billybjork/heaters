# Comprehensive Port.open debugging script
# This will test each option individually to find the problematic one

defmodule PortDebugger do
  def test_all do
    python_exe = "/opt/venv/bin/python3"
    working_dir = "/app"
    script_path = "/app/py_tasks/runner.py"
    tmp_file = "/tmp/debug_args.json"
    File.write!(tmp_file, "{\"test\": true}")

    args = [script_path, "intake", "--args-file", tmp_file]
    env = []

    IO.puts "=== Testing Port.open options systematically ==="
    IO.puts "python_exe: #{python_exe}"
    IO.puts "working_dir: #{working_dir}"
    IO.puts "args: #{inspect(args)}"
    IO.puts "env: #{inspect(env)}"
    IO.puts ""

    # Test 1: Minimal options
    test_port("Test 1: Minimal", python_exe, [:binary, :exit_status])

    # Test 2: Add hide
    test_port("Test 2: + :hide", python_exe, [:binary, :exit_status, :hide])

    # Test 3: Add line
    test_port("Test 3: + :line", python_exe, [:binary, :exit_status, :hide, :line])

    # Test 4: Add args
    test_port("Test 4: + {:args, args}", python_exe, [:binary, :exit_status, :hide, :line, {:args, args}])

    # Test 5: Add env
    test_port("Test 5: + {:env, env}", python_exe, [:binary, :exit_status, :hide, :line, {:args, args}, {:env, env}])

    # Test 6: Add cd
    test_port("Test 6: + {:cd, working_dir}", python_exe, [:binary, :exit_status, :hide, :line, {:args, args}, {:env, env}, {:cd, working_dir}])

    # Test alternative packet options
    IO.puts "\n=== Testing alternative packet options ==="
    test_port("Alt 1: {:packet, 4}", python_exe, [:binary, :exit_status, :hide, {:packet, 4}, {:args, args}, {:env, env}, {:cd, working_dir}])
    test_port("Alt 2: no packet", python_exe, [:binary, :exit_status, :hide, {:args, args}, {:env, env}, {:cd, working_dir}])

    # Test args validation
    IO.puts "\n=== Testing args content ==="
    IO.puts "File exists checks:"
    IO.puts "  python_exe exists? #{File.exists?(python_exe)}"
    IO.puts "  script_path exists? #{File.exists?(script_path)}"
    IO.puts "  working_dir exists? #{File.exists?(working_dir)}"
    IO.puts "  tmp_file exists? #{File.exists?(tmp_file)}"

    # Test with simpler args
    simple_args = ["--version"]
    test_port("Simple args: --version", python_exe, [:binary, :exit_status, {:args, simple_args}])

    File.rm(tmp_file)
  end

  defp test_port(test_name, python_exe, options) do
    try do
      port = Port.open({:spawn_executable, python_exe}, options)
      Port.close(port)
      IO.puts "✅ #{test_name}: SUCCESS"
    rescue
      e ->
        IO.puts "❌ #{test_name}: FAILED - #{Exception.message(e)}"
    end
  end
end

PortDebugger.test_all()
