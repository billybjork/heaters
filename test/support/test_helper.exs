defmodule Heaters.TestHelper do
  @moduledoc """
  Test helper utilities for Heaters workers and pipeline testing.

  Provides utilities for testing worker behavior without requiring
  full database setup or external dependencies.
  """

  @doc """
  Creates a mock Oban job struct for testing worker perform/1 functions.

  ## Examples

      job = TestHelper.mock_job(%{"clip_id" => 123, "split_at_frame" => 100})
      result = MyWorker.perform(job)
  """
  def mock_job(args) when is_map(args) do
    %Oban.Job{
      id: :rand.uniform(1000),
      args: args,
      worker: "TestWorker",
      queue: "test_queue",
      attempt: 1,
      attempted_at: DateTime.utc_now(),
      inserted_at: DateTime.utc_now(),
      scheduled_at: DateTime.utc_now()
    }
  end

  @doc """
  Simplifies testing worker callbacks without Oban job wrapper.

  ## Examples

      # Test just the handle/1 callback
      result = TestHelper.test_handle(MyWorker, %{"test" => "data"})

      # Test the full perform cycle
      result = TestHelper.test_perform(MyWorker, %{"test" => "data"})
  """
  def test_handle(worker_module, args) do
    worker_module.handle(args)
  end

  def test_perform(worker_module, args) do
    job = mock_job(args)
    worker_module.perform(job)
  end

  @doc """
  Captures and returns log output from a function.
  Useful for testing logging behavior.
  """
  defmacro capture_log_and_result(fun) do
    quote do
      import ExUnit.CaptureLog
      log = capture_log(unquote(fun))
      {log, unquote(fun).()}
    end
  end

  @doc """
  Asserts that a module implements the GenericWorker behavior correctly.
  """
  def assert_generic_worker_behavior(worker_module) do
    # Check required functions exist
    assert function_exported?(worker_module, :handle, 1),
           "#{worker_module} must implement handle/1"

    assert function_exported?(worker_module, :enqueue_next, 1),
           "#{worker_module} must implement enqueue_next/1"

    assert function_exported?(worker_module, :perform, 1),
           "#{worker_module} must implement perform/1 (from GenericWorker)"

    # Check behavior is implemented
    behaviors = worker_module.__info__(:attributes)[:behaviour] || []

    assert Heaters.Workers.GenericWorker in behaviors,
           "#{worker_module} must use GenericWorker behavior"
  end

  @doc """
  Mock function results for testing without external dependencies.
  """
  def mock_split_result(success: true) do
    {:ok, %{metadata: %{new_clip_ids: [101, 102]}}}
  end

  def mock_split_result(success: false) do
    {:error, "Mock split failure"}
  end

  def mock_split_result(unexpected: true) do
    {:ok, %{unexpected: "payload"}}
  end
end
