defmodule Heaters.Workers.Clips.SplitWorker do
  use Heaters.Workers.GenericWorker, queue: :media_processing

  alias Heaters.Clips.Transform.Split
  alias Heaters.Workers.Clips.SpriteWorker

  @impl Heaters.Workers.GenericWorker
  def handle(%{"clip_id" => clip_id, "split_at_frame" => split_at_frame}) do
    case Split.run_split(clip_id, split_at_frame) do
      {:ok, %{metadata: %{new_clip_ids: new_clip_ids}}} when is_list(new_clip_ids) ->
        # Store the new clip IDs for enqueue_next/1 to use
        Process.put(:new_clip_ids, new_clip_ids)
        :ok

      {:ok, other} ->
        {:error, "Split finished with unexpected payload: #{inspect(other)}"}

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
          {count, _} when count > 0 ->
            :ok
          _ ->
            {:error, "Failed to enqueue sprite worker jobs"}
        end

      _ ->
        {:error, "No new_clip_ids found to enqueue sprite workers"}
    end
  end
end
