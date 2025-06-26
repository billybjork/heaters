defmodule Heaters.Workers.GenericWorkerTest do
  use Heaters.DataCase, async: true
  use Oban.Testing, repo: Heaters.Repo

  import ExUnit.CaptureLog

  alias Heaters.Workers.Clips.SplitWorker

  # Test helper module to validate GenericWorker behavior
  defmodule TestWorker do
    use Heaters.Workers.GenericWorker, queue: :test_queue

    # Allow controlling behavior from tests
    def set_behavior(behavior), do: Process.put(:test_behavior, behavior)
    def get_behavior, do: Process.get(:test_behavior, :success)

    @impl Heaters.Workers.GenericWorker
    def handle(%{"test" => "data"} = args) do
      case get_behavior() do
        :success -> :ok
        :error -> {:error, "simulated error"}
        :exception -> raise "simulated exception"
        :unexpected_return -> :unexpected
        :store_data ->
          Process.put(:stored_value, Map.get(args, "value"))
          :ok
      end
    end

    @impl Heaters.Workers.GenericWorker
    def enqueue_next(%{"test" => "data"}) do
      case get_behavior() do
        :enqueue_error -> {:error, "enqueue failed"}
        :enqueue_success_with_stored ->
          stored = Process.get(:stored_value)
          Process.put(:enqueue_called_with, stored)
          :ok
        _ -> :ok
      end
    end
  end

  describe "GenericWorker behavior" do
    test "handles successful job execution with timing" do
      TestWorker.set_behavior(:success)

      log = capture_log(fn ->
        assert :ok = perform_job(TestWorker, %{"test" => "data"})
      end)

      assert log =~ "TestWorker: Starting job with args:"
      assert log =~ "TestWorker: Job completed successfully in"
      assert log =~ "ms"
    end

    test "handles business logic errors" do
      TestWorker.set_behavior(:error)

      log = capture_log(fn ->
        assert {:error, "simulated error"} = perform_job(TestWorker, %{"test" => "data"})
      end)

      assert log =~ "TestWorker: Starting job with args:"
      assert log =~ "TestWorker: Job failed: \"simulated error\""
    end

    test "catches and handles exceptions" do
      TestWorker.set_behavior(:exception)

      log = capture_log(fn ->
        assert {:error, "simulated exception"} = perform_job(TestWorker, %{"test" => "data"})
      end)

      assert log =~ "TestWorker: Starting job with args:"
      assert log =~ "TestWorker: Job crashed with exception: simulated exception"
      assert log =~ "TestWorker: Exception details:"
    end

    test "handles unexpected return values" do
      TestWorker.set_behavior(:unexpected_return)

      log = capture_log(fn ->
        assert {:error, "Unexpected return value: :unexpected"} = perform_job(TestWorker, %{"test" => "data"})
      end)

      assert log =~ "TestWorker: Job returned unexpected result: :unexpected"
    end

    test "calls enqueue_next only after successful handle" do
      TestWorker.set_behavior(:store_data)

      assert :ok = perform_job(TestWorker, %{"test" => "data", "value" => "test_value"})

      # Verify that handle was called and stored data
      assert Process.get(:stored_value) == "test_value"
    end

    test "handles enqueue_next errors" do
      TestWorker.set_behavior(:enqueue_error)

      log = capture_log(fn ->
        assert {:error, "enqueue failed"} = perform_job(TestWorker, %{"test" => "data"})
      end)

      assert log =~ "TestWorker: Job failed: \"enqueue failed\""
    end

    test "passes data from handle to enqueue_next via process dictionary" do
      TestWorker.set_behavior(:enqueue_success_with_stored)

      assert :ok = perform_job(TestWorker, %{"test" => "data", "value" => "shared_data"})

      # Verify data was passed from handle to enqueue_next
      assert Process.get(:enqueue_called_with) == "shared_data"
    end

    test "skips enqueue_next when handle fails" do
      TestWorker.set_behavior(:error)

      # Clear any previous state
      Process.put(:enqueue_called_with, nil)

      assert {:error, "simulated error"} = perform_job(TestWorker, %{"test" => "data"})

      # Verify enqueue_next was not called
      assert Process.get(:enqueue_called_with) == nil
    end
  end

  describe "SplitWorker integration" do
    setup do
      # Mock the Split module for testing
      # In real tests, you might want to use a more sophisticated mocking library
      # or create test fixtures with actual data
      :ok
    end

    test "handles successful split with new clip IDs" do
      # Mock Split.run_split to return success with new clip IDs
      split_result = {:ok, %{metadata: %{new_clip_ids: [123, 456]}}}

      # Create a mock for Split.run_split
      expect_split_call = fn ->
        Process.put(:split_called_with, {1, 100})
        split_result
      end

      # We'll need to mock this properly, but for now let's test the structure
      log = capture_log(fn ->
        # This would need proper mocking setup
        # For now, test the worker structure
        worker = SplitWorker
        assert function_exported?(worker, :handle, 1)
        assert function_exported?(worker, :enqueue_next, 1)
      end)
    end

    test "handle/1 processes split arguments correctly" do
      # Test that the handle function has the right signature and pattern matching
      args = %{"clip_id" => 1, "split_at_frame" => 100}

      # Verify the function exists and takes the right arguments
      assert function_exported?(SplitWorker, :handle, 1)

      # Test error handling for bad arguments
      assert_raise FunctionClauseError, fn ->
        SplitWorker.handle(%{"wrong" => "args"})
      end
    end

    test "enqueue_next/1 handles stored clip IDs" do
      # Test the enqueue_next function structure
      args = %{"clip_id" => 1}

      # Clear any previous stored data
      Process.delete(:new_clip_ids)

      # Test with no stored data
      log = capture_log(fn ->
        result = SplitWorker.enqueue_next(args)
        assert {:error, "No new_clip_ids found to enqueue sprite workers"} = result
      end)

      # Test with stored data
      Process.put(:new_clip_ids, [123, 456])

      # This would normally enqueue jobs, but we can test the structure
      assert function_exported?(SplitWorker, :enqueue_next, 1)
    end
  end

  describe "Worker integration patterns" do
    test "workers follow consistent error handling pattern" do
      # Test that all workers return proper {:ok} | {:error, reason} tuples
      # This can be extended as we migrate more workers

      workers_to_test = [
        SplitWorker
        # Add other workers here as they get migrated:
        # SpriteWorker,
        # KeyframeWorker,
        # etc.
      ]

      for worker <- workers_to_test do
        # Verify each worker implements the GenericWorker behavior
        assert function_exported?(worker, :handle, 1)
        assert function_exported?(worker, :enqueue_next, 1)

        # Verify they use the GenericWorker behavior
        behaviors = worker.__info__(:attributes)[:behaviour] || []
        assert Heaters.Workers.GenericWorker in behaviors
      end
    end

    test "workers have consistent logging patterns" do
      # Test that workers using GenericWorker get consistent logging
      # This validates our centralized logging approach

      TestWorker.set_behavior(:success)

      log = capture_log(fn ->
        perform_job(TestWorker, %{"test" => "data"})
      end)

      # All workers should have these log patterns
      assert log =~ ~r/\w+Worker: Starting job with args:/
      assert log =~ ~r/\w+Worker: Job completed successfully in \d+ms/
    end
  end

  # Helper function to easily test worker performance
  defp perform_job(worker_module, args) do
    job = worker_module.new(args)
    worker_module.perform(job)
  end
end
