defmodule Heaters.Workers.Dispatcher do
  use Oban.Worker, queue: :background_jobs, unique: [period: 60]

  require Logger

  alias Heaters.Workers.PipelineConfig

  @impl Oban.Worker
  def perform(_job) do
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
      Oban.insert_all(jobs, on_conflict: :raise)

      Logger.info("Dispatcher[step #{step_num}]: Finished enqueuing #{Enum.count(jobs)} jobs for #{label}.")
    end
  end

  # Handle stages that perform direct actions (like EventProcessor)
  defp run_stage(%{call: call_fn, label: label}, step_num) do
    Logger.info("Dispatcher[step #{step_num}]: #{String.capitalize(label)}.")

    call_fn.()

    Logger.info("Dispatcher[step #{step_num}]: Finished #{label}.")
  end
end
