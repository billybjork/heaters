defmodule Heaters.Infrastructure.Orchestration.Dispatcher do
  use Heaters.Infrastructure.Orchestration.WorkerBehavior,
    queue: :background_jobs,
    unique: [period: 60]

  alias Heaters.Infrastructure.Orchestration.PipelineConfig
  alias Heaters.Infrastructure.Orchestration.WorkerBehavior
  alias Ecto.Multi

  @impl WorkerBehavior
  def handle_work(_args) do
    Logger.info("Dispatcher[start]: Starting perform.")

    # Process all pipeline stages using the declarative configuration
    PipelineConfig.stages()
    |> Enum.with_index(1)
    |> Enum.each(fn {stage, step_num} ->
      run_stage(stage, step_num)
    end)

    Logger.info("Dispatcher[finish]: Finished perform.")
    :ok
  end

  # Handle stages that query the database and enqueue jobs
  defp run_stage(%{query: query_fn, build: build_fn, label: label}, step_num) do
    Logger.info("Dispatcher[step #{step_num}]: Checking for #{label}.")

    items = query_fn.()
    Logger.info("Dispatcher[step #{step_num}]: Found #{Enum.count(items)} items for #{label}.")

    if Enum.any?(items) do
      Logger.info("Dispatcher[step #{step_num}]: Enqueuing jobs for #{label}.")

      jobs = Enum.map(items, build_fn)

      # Use :nothing instead of :raise to gracefully handle duplicate jobs
      # This works with unique constraints to prevent duplicate processing
      result = Oban.insert_all(jobs, on_conflict: :nothing)

      case result do
        # Handle list format [jobs] when some jobs were inserted
        inserted_jobs when is_list(inserted_jobs) and length(inserted_jobs) > 0 ->
          Logger.info(
            "Dispatcher[step #{step_num}]: Enqueued #{length(inserted_jobs)} new jobs for #{label}."
          )

        # Handle empty list when no jobs were inserted (all duplicates)
        [] ->
          Logger.info(
            "Dispatcher[step #{step_num}]: No new jobs needed for #{label} (all jobs already exist)."
          )

        # Handle Ecto.Multi format (shouldn't happen but dialyzer sees it as possible)
        %Multi{} = _multi ->
          Logger.warning(
            "Dispatcher[step #{step_num}]: Unexpected Ecto.Multi result from Oban.insert_all for #{label}."
          )
      end
    end
  end

      # Handle stages that perform direct actions (like database maintenance)
  defp run_stage(%{call: call_fn, label: label}, step_num) do
    Logger.info("Dispatcher[step #{step_num}]: #{String.capitalize(label)}.")

    call_fn.()

    Logger.info("Dispatcher[step #{step_num}]: Finished #{label}.")
  end
end
