defmodule Heaters.Workers.Clip.SplitWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Clip.Transform.Split
  alias Heaters.Workers.Clip.SpriteWorker
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "clip_id" => clip_id,
          "split_at_frame" => split_at_frame
        }
      }) do
    Logger.info("SplitWorker: Processing split for clip_id=#{clip_id}, split_at_frame=#{split_at_frame}")

    case Split.run_split(clip_id, split_at_frame) do
      {:ok, %{metadata: %{new_clip_ids: new_clip_ids}}} when is_list(new_clip_ids) ->
        # The split was successful. The original clip has been archived and two
        # new clips created. We'll enqueue SpriteWorker jobs for both to
        # generate sprites and put them into the review queue.
        Logger.info("SplitWorker: Split successful, enqueuing sprite workers for #{length(new_clip_ids)} new clips")
        jobs = Enum.map(new_clip_ids, &SpriteWorker.new(%{clip_id: &1}))

        try do
          _inserted_jobs = Oban.insert_all(jobs)
          Logger.info("SplitWorker: Successfully enqueued #{length(jobs)} sprite worker jobs")
          :ok
        rescue
          error ->
            Logger.error("SplitWorker: Failed to enqueue sprite workers: #{Exception.message(error)}")
            {:error, "Failed to enqueue sprite workers: #{Exception.message(error)}"}
        end

      {:ok, other} ->
        # The split succeeded but returned an unexpected payload.
        Logger.error("SplitWorker: Split finished with unexpected payload: #{inspect(other)}")
        {:error, "Split finished with unexpected payload: #{inspect(other)}"}

      {:error, reason} ->
        # The split failed.
        Logger.error("SplitWorker: Split failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
