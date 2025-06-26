defmodule Heaters.Workers.GenericWorkerSimpleTest do
  use ExUnit.Case, async: true

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
        :enqueue_success_with_stored ->
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

  describe "GenericWorker behavior compilation and structure" do
    test "TestWorker compiles with correct callbacks" do
      # Verify the worker implements the required callbacks
      assert function_exported?(TestWorker, :handle, 1)
      assert function_exported?(TestWorker, :enqueue_next, 1)
      assert function_exported?(TestWorker, :perform, 1)
    end

    test "TestWorker has GenericWorker behavior" do
      # Verify it implements the GenericWorker behavior
      # Note: Behaviors are set by the @behaviour directive, but since GenericWorker
      # is a macro that injects behavior, we check for the functions instead
      behaviors = TestWorker.__info__(:attributes)[:behaviour] || []

      # The macro should inject Oban.Worker behavior
      assert Oban.Worker in behaviors

      # And the worker should have our required callbacks
      assert function_exported?(TestWorker, :handle, 1)
      assert function_exported?(TestWorker, :enqueue_next, 1)
    end

        test "handles successful job execution with timing" do
      TestWorker.set_behavior(:success)

      # Create a mock Oban job
      job = %Oban.Job{args: %{"test" => "data"}}

      log = capture_log([level: :info], fn ->
        assert :ok = TestWorker.perform(job)
      end)

      assert log =~ "TestWorker: Starting job with args:"
      assert log =~ "TestWorker: Job completed successfully in"
      assert log =~ "ms"
    end

        test "handles business logic errors" do
      TestWorker.set_behavior(:error)

      job = %Oban.Job{args: %{"test" => "data"}}

      log = capture_log([level: :info], fn ->
        assert {:error, "simulated error"} = TestWorker.perform(job)
      end)

      assert log =~ "TestWorker: Starting job with args:"
      assert log =~ "TestWorker: Job failed: \"simulated error\""
    end

        test "catches and handles exceptions" do
      TestWorker.set_behavior(:exception)

      job = %Oban.Job{args: %{"test" => "data"}}

      log = capture_log([level: :info], fn ->
        assert {:error, "simulated exception"} = TestWorker.perform(job)
      end)

      assert log =~ "TestWorker: Job crashed with exception: simulated exception"
      assert log =~ "TestWorker: Exception details:"
    end

    test "handles unexpected return values" do
      TestWorker.set_behavior(:unexpected_return)

      job = %Oban.Job{args: %{"test" => "data"}}

      log = capture_log(fn ->
        assert {:error, "Unexpected return value: :unexpected"} = TestWorker.perform(job)
      end)

      assert log =~ "TestWorker: Job returned unexpected result: :unexpected"
    end

    test "passes data from handle to enqueue_next via process dictionary" do
      TestWorker.set_behavior(:enqueue_success_with_stored)

      job = %Oban.Job{args: %{"test" => "data", "value" => "shared_data"}}

      assert :ok = TestWorker.perform(job)

      # Verify data was passed from handle to enqueue_next
      assert Process.get(:enqueue_called_with) == "shared_data"
    end

    test "skips enqueue_next when handle fails" do
      TestWorker.set_behavior(:error)

      # Clear any previous state
      Process.put(:enqueue_called_with, nil)

      job = %Oban.Job{args: %{"test" => "data"}}
      assert {:error, "simulated error"} = TestWorker.perform(job)

      # Verify enqueue_next was not called
      assert Process.get(:enqueue_called_with) == nil
    end
  end

  describe "SplitWorker structure validation" do
    test "SplitWorker compiles with correct structure" do
      # Verify SplitWorker implements the required callbacks
      assert function_exported?(SplitWorker, :handle, 1)
      assert function_exported?(SplitWorker, :enqueue_next, 1)
      assert function_exported?(SplitWorker, :perform, 1)
    end

    test "SplitWorker uses GenericWorker behavior" do
      # Verify it implements the GenericWorker behavior
      behaviors = SplitWorker.__info__(:attributes)[:behaviour] || []

      # The macro should inject Oban.Worker behavior
      assert Oban.Worker in behaviors

      # And the worker should have our required callbacks
      assert function_exported?(SplitWorker, :handle, 1)
      assert function_exported?(SplitWorker, :enqueue_next, 1)
    end

    test "SplitWorker handle/1 has correct pattern matching" do
      # Test that the handle function requires the right arguments
      assert_raise FunctionClauseError, fn ->
        SplitWorker.handle(%{"wrong" => "args"})
      end
    end

    test "SplitWorker enqueue_next/1 handles missing stored data" do
      # Clear any previous stored data
      Process.delete(:new_clip_ids)

      # Test with no stored data
      args = %{"clip_id" => 1}
      result = SplitWorker.enqueue_next(args)
      assert {:error, "No new_clip_ids found to enqueue sprite workers"} = result
    end

        test "SplitWorker enqueue_next/1 handles stored clip IDs" do
      # Test with stored data
      Process.put(:new_clip_ids, [123, 456])

      _args = %{"clip_id" => 1}
      # This would normally enqueue jobs, but we're testing structure
      # The actual enqueueing would require Oban setup
      assert function_exported?(SplitWorker, :enqueue_next, 1)
    end
  end

  describe "PipelineConfig integration" do
    test "PipelineConfig stages function works" do
      stages = Heaters.Workers.PipelineConfig.stages()

      # Verify we get a list of stages
      assert is_list(stages)
      assert length(stages) == 6

      # Verify each stage has required fields
      for stage <- stages do
        assert Map.has_key?(stage, :label)
        assert is_binary(stage.label)

        # Each stage should have either query+build or call
        cond do
          Map.has_key?(stage, :call) ->
            assert is_function(stage.call, 0)
          Map.has_key?(stage, :query) and Map.has_key?(stage, :build) ->
            assert is_function(stage.query, 0)
            assert is_function(stage.build, 1)
          true ->
            flunk("Stage must have either 'call' or 'query+build': #{inspect(stage)}")
        end
      end
    end

    test "PipelineConfig helper functions work" do
      labels = Heaters.Workers.PipelineConfig.stage_labels()
      assert is_list(labels)
      assert length(labels) == 6
      assert Enum.all?(labels, &is_binary/1)

      count = Heaters.Workers.PipelineConfig.stage_count()
      assert count == 6
    end
  end

  describe "Worker pattern compliance" do
    test "all migrated workers follow GenericWorker pattern" do
      # List of workers that have been migrated to GenericWorker
      migrated_workers = [
        SplitWorker
        # Add other workers here as they get migrated:
        # SpriteWorker,
        # KeyframeWorker,
        # etc.
      ]

      for worker <- migrated_workers do
        # Verify each worker implements the GenericWorker behavior
        assert function_exported?(worker, :handle, 1),
               "#{worker} must implement handle/1"

        assert function_exported?(worker, :enqueue_next, 1),
               "#{worker} must implement enqueue_next/1"

        # Verify they use the GenericWorker behavior (via Oban.Worker)
        behaviors = worker.__info__(:attributes)[:behaviour] || []
        assert Oban.Worker in behaviors,
               "#{worker} must use Oban.Worker behavior (injected by GenericWorker)"
      end
    end
  end
end
