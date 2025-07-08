defmodule Heaters.Workers.Clips.SplitWorker do
  use Oban.Worker, queue: :media_processing

  alias Heaters.Clips.Operations.Edits.Split
  alias Heaters.Clips.Operations.Shared.Types
  alias Heaters.Workers.Clips.SpriteWorker

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    module_name = __MODULE__ |> Module.split() |> List.last()
    Logger.info("#{module_name}: Starting job with args: #{inspect(args)}")

    start_time = System.monotonic_time()

    try do
      with :ok <- handle_split_work(args),
           :ok <- enqueue_next_work(args) do
        duration_ms =
          System.convert_time_unit(
            System.monotonic_time() - start_time,
            :native,
            :millisecond
          )

        Logger.info("#{module_name}: Job completed successfully in #{duration_ms}ms")
        :ok
      else
        {:error, reason} ->
          Logger.error("#{module_name}: Job failed: #{inspect(reason)}")
          {:error, reason}

        other ->
          Logger.error("#{module_name}: Job returned unexpected result: #{inspect(other)}")
          {:error, "Unexpected return value: #{inspect(other)}"}
      end
    rescue
      error ->
        Logger.error("#{module_name}: Job crashed with exception: #{Exception.message(error)}")

        Logger.error(
          "#{module_name}: Exception details: #{Exception.format(:error, error, __STACKTRACE__)}"
        )

        {:error, Exception.message(error)}
    catch
      :exit, reason ->
        Logger.error("#{module_name}: Job exited with reason: #{inspect(reason)}")
        {:error, "Process exit: #{inspect(reason)}"}

      :throw, value ->
        Logger.error("#{module_name}: Job threw value: #{inspect(value)}")
        {:error, "Thrown value: #{inspect(value)}"}
    end
  end

  defp handle_split_work(%{"clip_id" => clip_id, "split_at_frame" => split_at_frame}) do
    case Split.run_split(clip_id, split_at_frame) do
      {:ok, %Types.SplitResult{status: "success", new_clip_ids: new_clip_ids}}
      when is_list(new_clip_ids) ->
        # Store the new clip IDs for enqueue_next_work/1 to use
        Process.put(:new_clip_ids, new_clip_ids)
        :ok

      {:ok, %Types.SplitResult{status: status}} ->
        {:error, "Split finished with unexpected status: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_next_work(%{"clip_id" => _clip_id}) do
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
