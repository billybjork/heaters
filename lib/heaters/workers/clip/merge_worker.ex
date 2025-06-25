defmodule Heaters.Workers.Clip.MergeWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Clip.Transform.Merge
  alias Heaters.Workers.Clip.SpriteWorker
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "clip_id_target" => clip_id_target,
          "clip_id_source" => clip_id_source
        }
      }) do
    Logger.info("MergeWorker: Starting merge for target_clip_id: #{clip_id_target}, source_clip_id: #{clip_id_source}")

    case Merge.run_merge(clip_id_target, clip_id_source) do
      {:ok, %{merged_clip_id: merged_clip_id}} ->
        Logger.info("MergeWorker: Merge succeeded for clips #{clip_id_target}, #{clip_id_source}. New clip: #{merged_clip_id}")

        # The merge was successful. The new clip is in "spliced" state.
        # We'll enqueue a SpriteWorker job to generate its sprite and put it in the review queue.
        case SpriteWorker.new(%{clip_id: merged_clip_id}) |> Oban.insert() do
          {:ok, _job} ->
            Logger.info("MergeWorker: Successfully enqueued SpriteWorker for merged clip #{merged_clip_id}")
            :ok
          {:error, reason} ->
            Logger.error("MergeWorker: Failed to enqueue sprite worker: #{inspect(reason)}")
            {:error, "Failed to enqueue sprite worker: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("MergeWorker: Merge failed for clips #{clip_id_target}, #{clip_id_source}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
