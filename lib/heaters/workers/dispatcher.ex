defmodule Heaters.Workers.Dispatcher do
  use Oban.Worker, queue: :orchestration

  alias Heaters.Video.Queries, as: VideoQueries
  alias Heaters.Workers.Video.IngestWorker
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Dispatcher: Starting orchestration step")

    # Step 1: Find new videos and enqueue IngestWorker jobs
    case VideoQueries.get_videos_by_state("new") do
      [] ->
        Logger.info("Dispatcher[step 1]: No new videos found")

      new_videos ->
        Logger.info("Dispatcher[step 1]: Found #{length(new_videos)} new videos")
        Logger.info("Dispatcher[step 1]: Enqueuing IngestWorker jobs.")
        new_jobs = Enum.map(new_videos, &IngestWorker.new(%{source_video_id: &1.id}))
        Oban.insert_all(new_jobs, on_conflict: :raise)
        Logger.info("Dispatcher[step 1]: Finished enqueuing IngestWorker jobs.")
    end

    # Add more orchestration steps here as needed
    # Step 2: Handle failed jobs
    # Step 3: Cleanup old jobs
    # etc.

    :ok
  rescue
    e ->
      Logger.error("Dispatcher: Error during orchestration: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end
end
