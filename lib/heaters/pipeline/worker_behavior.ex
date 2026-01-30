defmodule Heaters.Pipeline.WorkerBehavior do
  require Logger

  @moduledoc """
  Shared behavior for all Heaters workers to eliminate boilerplate and ensure consistency.

  This behavior provides production-grade reliability features:
  - Standardized performance monitoring and logging with automatic timing
  - Consistent error handling with comprehensive stack traces and exception recovery
  - Idempotency patterns for safe retries and resumable processing
  - Common helpers for resource not found and already processed scenarios
  - Centralized job lifecycle management with robust error handling

  Eliminates 450+ lines of boilerplate across all workers while maintaining full functionality.

  ## Usage

      defmodule MyWorker do
        use Heaters.Pipeline.WorkerBehavior, queue: :media_processing

        @impl WorkerBehavior
        def handle_work(%{"clip_id" => clip_id}) do
          # Your business logic here - infrastructure concerns handled by behavior
          :ok
        end
      end

  Workers focus purely on domain logic while the behavior handles all infrastructure concerns.
  """

  @doc """
  Callback for handling the actual work logic.
  Should return :ok, {:ok, result}, or {:error, reason}.
  """
  @callback handle_work(map()) :: :ok | {:ok, any()} | {:error, any()}

  defmacro __using__(opts) do
    queue = Keyword.get(opts, :queue, :default)
    unique_opts = Keyword.get(opts, :unique)

    oban_opts =
      if unique_opts do
        [queue: queue, unique: unique_opts]
      else
        [queue: queue]
      end

    quote do
      use Oban.Worker, unquote(oban_opts)

      @behaviour Heaters.Pipeline.WorkerBehavior
      require Logger

      @impl Oban.Worker
      def perform(%Oban.Job{args: args}) do
        unquote(__MODULE__).execute_with_monitoring(
          __MODULE__,
          args
        )
      end
    end
  end

  @doc """
  Executes worker logic with standardized monitoring and error handling.
  """
  def execute_with_monitoring(worker_module, args) do
    module_name = worker_module |> Module.split() |> List.last()
    Logger.info("#{module_name}: Starting job with args: #{inspect(args)}")

    start_time = System.monotonic_time()

    try do
      case worker_module.handle_work(args) do
        :ok ->
          log_success(module_name, start_time)
          :ok

        {:ok, result} when is_map(result) or is_list(result) ->
          # Some workers return results
          log_success(module_name, start_time)
          {:ok, result}

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

        Logger.error(
          "#{module_name}: Exception details: #{Exception.format(:error, error, __STACKTRACE__)}"
        )

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

  defp log_success(module_name, start_time) do
    duration_ms =
      System.convert_time_unit(
        System.monotonic_time() - start_time,
        :native,
        :millisecond
      )

    Logger.info("#{module_name}: Job completed successfully in #{duration_ms}ms")
  end

  ## Common Idempotency Helpers

  @doc """
  Helper for checking if entity is in complete states.
  """
  def check_complete_states(entity, complete_states) when is_list(complete_states) do
    if entity.ingest_state in complete_states do
      {:error, :already_processed}
    else
      :ok
    end
  end

  @doc """
  Helper for checking if clip has artifacts of a specific type.
  """
  def check_artifact_exists(clip, artifact_type) do
    normalized_target = to_string(artifact_type)

    has_artifact? =
      clip.clip_artifacts
      |> Enum.any?(fn a -> to_string(a.artifact_type) == normalized_target end)

    if has_artifact? do
      {:error, :already_processed}
    else
      :ok
    end
  end

  @doc """
  Standard handler for not found entities.
  """
  def handle_not_found(entity_type, entity_id) do
    Logger.warning("#{entity_type} #{entity_id} not found, likely deleted")
    :ok
  end

  @doc """
  Standard handler for already processed entities.
  """
  def handle_already_processed(entity_type, entity_id) do
    Logger.info("#{entity_type} #{entity_id} already processed, skipping")
    :ok
  end

  ## Job Enqueuing Helpers

  @doc """
  Helper for enqueuing multiple jobs with error handling.
  """
  def enqueue_jobs(jobs, context_name) when is_list(jobs) do
    case Oban.insert_all(jobs) do
      [_ | _] = inserted_jobs ->
        Logger.info("#{context_name}: Enqueued #{length(inserted_jobs)} jobs")
        :ok

      [] ->
        Logger.error("#{context_name}: Failed to enqueue jobs - no jobs inserted")
        {:error, "No jobs were enqueued"}

      %Ecto.Multi{} = multi ->
        Logger.error(
          "#{context_name}: Oban.insert_all returned Multi instead of jobs: #{inspect(multi)}"
        )

        {:error, "Unexpected Multi result from Oban.insert_all"}
    end
  rescue
    error ->
      error_message = "Failed to enqueue jobs: #{Exception.message(error)}"
      Logger.error("#{context_name}: #{error_message}")
      {:error, error_message}
  end

  @doc """
  Helper for enqueuing a single job with error handling.
  """
  def enqueue_single_job(job, context_name) do
    case Oban.insert(job) do
      {:ok, _job} ->
        Logger.info("#{context_name}: Successfully enqueued job")
        :ok

      {:error, reason} ->
        Logger.error("#{context_name}: Failed to enqueue job: #{inspect(reason)}")
        {:error, "Failed to enqueue job: #{inspect(reason)}"}
    end
  end
end
