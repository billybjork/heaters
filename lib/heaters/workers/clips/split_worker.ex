defmodule Heaters.Workers.Clips.SplitWorker do
  use Heaters.Workers.GenericWorker, queue: :media_processing

  alias Heaters.Clips.Operations.Edits.Split
  alias Heaters.Clips.Operations.Shared.Types
  alias Heaters.Workers.Clips.SpriteWorker

  @impl Heaters.Workers.GenericWorker
  def handle(%{"clip_id" => clip_id, "split_at_frame" => split_at_frame}) do
    case Split.run_split(clip_id, split_at_frame) do
      {:ok, %Types.SplitResult{status: "success", new_clip_ids: new_clip_ids}}
      when is_list(new_clip_ids) ->
        # Store the new clip IDs for enqueue_next/1 to use
        Process.put(:new_clip_ids, new_clip_ids)
        :ok

      {:ok, %Types.SplitResult{status: status}} ->
        {:error, "Split finished with unexpected status: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Heaters.Workers.GenericWorker
  def enqueue_next(%{"clip_id" => _clip_id}) do
    case Process.get(:new_clip_ids) do
      new_clip_ids when is_list(new_clip_ids) ->
        # The split was successful. The original clip has been archived and two
        # new clips created. We'll enqueue SpriteWorker jobs for both to
        # generate sprites and put them into the review queue.
        jobs = Enum.map(new_clip_ids, &SpriteWorker.new(%{clip_id: &1}))

        case Oban.insert_all(jobs) do
          [_ | _] = job_list when is_list(job_list) ->
            :ok

          [] ->
            {:error, "No jobs were inserted"}

          %Ecto.Multi{} = _multi ->
            # When used inside a transaction, Oban.insert_all returns an Ecto.Multi
            # We treat this as success since the jobs will be inserted when the transaction commits
            :ok
        end

      _ ->
        {:error, "No new_clip_ids found to enqueue sprite workers"}
    end
  end
end
