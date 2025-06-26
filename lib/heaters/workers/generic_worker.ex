defmodule Heaters.Workers.GenericWorker do
  @moduledoc """
  Generic worker behavior that eliminates boilerplate across all workers.

  Provides:
  - Standardized error handling and logging
  - Automatic next-stage job enqueuing
  - Consistent telemetry and observability
  - Centralized retry logic
  - Graceful error recovery patterns

  ## Usage

  Instead of implementing Oban.Worker directly, use this behavior:

      defmodule MyWorker do
        use Heaters.Workers.GenericWorker, queue: :media_processing

        @impl Heaters.Workers.GenericWorker
        def handle(%{"item_id" => id}) do
          # Your business logic here
          case MyTask.process(id) do
            {:ok, _result} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

        @impl Heaters.Workers.GenericWorker
        def enqueue_next(%{"item_id" => id}) do
          # Enqueue follow-up jobs
          NextWorker.new(%{item_id: id})
          |> Oban.insert()
          :ok
        end
      end

  ## Callbacks

  - `handle/1` - Implement your core business logic
  - `enqueue_next/1` - Enqueue follow-up jobs (optional, defaults to no-op)

  ## Error Handling

  The behavior provides automatic error handling with:
  - Structured logging of successes and failures
  - Exception catching and conversion to error tuples
  - Performance timing and metrics
  - Consistent error message formatting
  """

  defmacro __using__(opts) do
    quote do
      use Oban.Worker, unquote(opts)
      @behaviour Heaters.Workers.GenericWorker
      require Logger

      @impl Oban.Worker
      def perform(%Oban.Job{args: args} = job) do
        module_name = __MODULE__ |> Module.split() |> List.last()
        Logger.info("#{module_name}: Starting job with args: #{inspect(args)}")

        start_time = System.monotonic_time()

        try do
          with :ok <- handle(args),
               :ok <- enqueue_next(args) do
            duration_ms = System.convert_time_unit(
              System.monotonic_time() - start_time,
              :native,
              :millisecond
            )
            Logger.info("#{module_name}: Job completed successfully in #{duration_ms}ms")
            :ok
          else
            {:error, reason} ->
              Logger.error("#{module_name}: Job failed: #{inspect(reason)}")
              {:error, reason}

            other ->
              Logger.error("#{module_name}: Job returned unexpected result: #{inspect(other)}")
              {:error, "Unexpected return value: #{inspect(other)}"}
          end
        rescue
          error ->
            Logger.error("#{module_name}: Job crashed with exception: #{Exception.message(error)}")
            Logger.error("#{module_name}: Exception details: #{Exception.format(:error, error, __STACKTRACE__)}")
            {:error, Exception.message(error)}
        catch
          :exit, reason ->
            Logger.error("#{module_name}: Job exited with reason: #{inspect(reason)}")
            {:error, "Process exit: #{inspect(reason)}"}

          :throw, value ->
            Logger.error("#{module_name}: Job threw value: #{inspect(value)}")
            {:error, "Thrown value: #{inspect(value)}"}
        end
      end

      # Callbacks to implement in concrete modules
      @callback handle(map()) :: :ok | {:error, term()}
      @callback enqueue_next(map()) :: :ok | {:error, term()}

      # Default implementation for workers that don't enqueue next jobs
      @doc """
      Default implementation that does nothing.
      Override this function to enqueue follow-up jobs.
      """
      def enqueue_next(_args), do: :ok

      # Allow overriding the default enqueue_next implementation
      defoverridable enqueue_next: 1
    end
  end

  @doc """
  Behavior definition for generic workers.

  ## Callbacks

  ### handle/1

  Implement your core business logic in this function. It should:
  - Take the job args as a map
  - Return `:ok` on success
  - Return `{:error, reason}` on failure
  - Focus only on the transformation/processing work

  ### enqueue_next/1 (optional)

  Implement this to enqueue follow-up jobs. It should:
  - Take the same job args as `handle/1`
  - Return `:ok` on success
  - Return `{:error, reason}` on failure
  - Only be called if `handle/1` succeeds

  The default implementation is a no-op, so you only need to implement this
  if your worker needs to enqueue subsequent jobs.
  """

  # Callback specifications for documentation and dialyzer
  @callback handle(args :: map()) :: :ok | {:error, term()}
  @callback enqueue_next(args :: map()) :: :ok | {:error, term()}
end
