defmodule Heaters.Clips.Operations.Edits.Split.Worker do
  use Heaters.Infrastructure.Orchestration.WorkerBehavior, queue: :media_processing

  alias Heaters.Clips.Operations.Edits.Split
  alias Heaters.Clips.Operations.Shared.Types
  alias Heaters.Infrastructure.Orchestration.WorkerBehavior
  require Logger

  @impl WorkerBehavior
  def handle_work(args) do
    handle_split_work(args)
  end

  defp handle_split_work(%{"clip_id" => clip_id, "split_at_frame" => split_at_frame}) do
    case Split.run_split(clip_id, split_at_frame) do
      {:ok, %Types.SplitResult{status: "success", new_clip_ids: new_clip_ids}}
      when is_list(new_clip_ids) ->
        :ok

      {:ok, %Types.SplitResult{status: status}} ->
        {:error, "Split finished with unexpected status: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
