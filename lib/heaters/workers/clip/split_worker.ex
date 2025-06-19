defmodule Heaters.Workers.Clip.SplitWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Infrastructure.PyRunner
  alias Heaters.Workers.Clip.SpriteWorker

  # Dialyzer cannot statically verify PyRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, perform: 1}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "clip_id" => clip_id,
          "split_at_frame" => split_at_frame
        }
      }) do
    py_args = %{clip_id: clip_id, split_at_frame: split_at_frame}

    case PyRunner.run("split", py_args) do
      {:ok, %{"result" => %{"new_clip_ids" => new_clip_ids}}} when is_list(new_clip_ids) ->
        # The split was successful. The original clip has been archived and two
        # new clips created. We'll enqueue SpriteWorker jobs for both to
        # generate sprites and put them into the review queue.
        jobs = Enum.map(new_clip_ids, &SpriteWorker.new(%{clip_id: &1}))

        try do
          _inserted_jobs = Oban.insert_all(jobs)
          :ok
        rescue
          error -> {:error, "Failed to enqueue sprite workers: #{Exception.message(error)}"}
        end

      {:ok, other} ->
        # The script succeeded but returned an unexpected payload.
        {:error, "Split script finished with unexpected payload: #{inspect(other)}"}

      {:error, reason} ->
        # The script failed. It should have updated the DB state itself.
        # We return an error to let Oban know the job failed.
        {:error, reason}
    end
  end
end
