defmodule Heaters.Workers.Clip.MergeWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Infrastructure.PyRunner
  alias Heaters.Workers.Clip.SpriteWorker

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, perform: 1}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "clip_id_target" => clip_id_target,
          "clip_id_source" => clip_id_source
        }
      }) do
    py_args = %{clip_id_target: clip_id_target, clip_id_source: clip_id_source}

    case PyRunner.run("merge", py_args) do
      {:ok, %{"result" => %{"merged_clip_id" => merged_clip_id}}} ->
        # The merge was successful. The target clip has been modified and its
        # state set back to "spliced". We'll enqueue a SpriteWorker job to
        # regenerate its sprite and put it back into the review queue.
        case SpriteWorker.new(%{clip_id: merged_clip_id}) |> Oban.insert() do
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, "Failed to enqueue sprite worker: #{inspect(reason)}"}
        end

      {:ok, other} ->
        # The script succeeded but returned an unexpected payload.
        {:error, "Merge script finished with unexpected payload: #{inspect(other)}"}

      {:error, reason} ->
        # The script failed. It should have updated the DB state itself.
        # We return an error to let Oban know the job failed.
        {:error, reason}
    end
  end
end
