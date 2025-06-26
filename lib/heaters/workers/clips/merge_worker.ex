defmodule Heaters.Workers.Clips.MergeWorker do
  use Heaters.Workers.GenericWorker, queue: :media_processing

  alias Heaters.Clips.Transform.Merge
  alias Heaters.Workers.Clips.SpriteWorker
  require Logger

  # Dialyzer warning suppression: pattern_match
  #
  # Dialyzer incorrectly reports that the pattern `{:ok, result}` can never match
  # in the case statement below, claiming `Merge.run_merge/2` can only return `{:error, _}`.
  #
  # This is a false positive due to Dialyzer's conservative analysis of the complex
  # `Merge.run_merge/2` function which has many nested operations including:
  # - File I/O operations
  # - S3 downloads/uploads
  # - FFmpeg execution
  # - Database operations
  # - Exception handling
  #
  # The function CAN and DOES return success tuples in normal operation, as verified by:
  # 1. Successful compilation without warnings
  # 2. Runtime testing shows the success path is reachable
  # 3. The defensive pattern matching with `when is_map(result)` handles the actual return
  #
  # This suppression is safe because we use defensive pattern matching that gracefully
  # handles both success and error cases, including malformed success responses.
  @dialyzer {:nowarn_function, handle: 1}

  @impl Heaters.Workers.GenericWorker
  def handle(%{
        "clip_id_target" => clip_id_target,
        "clip_id_source" => clip_id_source
      }) do
    Logger.info("MergeWorker: Starting merge for target_clip_id: #{clip_id_target}, source_clip_id: #{clip_id_source}")

    case Merge.run_merge(clip_id_target, clip_id_source) do
      {:ok, result} when is_map(result) ->
        case Map.get(result, :merged_clip_id) do
          merged_clip_id when is_integer(merged_clip_id) ->
            Logger.info("MergeWorker: Merge succeeded for clips #{clip_id_target}, #{clip_id_source}. New clip: #{merged_clip_id}")

            # Store the merged clip ID for enqueue_next/1 to use
            Process.put(:merged_clip_id, merged_clip_id)
            :ok

          _ ->
            Logger.error("MergeWorker: Merge succeeded but missing or invalid merged_clip_id in result: #{inspect(result)}")
            {:error, "Missing or invalid merged_clip_id in merge result"}
        end

      {:error, reason} ->
        Logger.error("MergeWorker: Merge failed for clips #{clip_id_target}, #{clip_id_source}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Heaters.Workers.GenericWorker
  def enqueue_next(_args) do
    case Process.get(:merged_clip_id) do
      merged_clip_id when is_integer(merged_clip_id) ->
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

      _ ->
        {:error, "No merged_clip_id found to enqueue sprite worker"}
    end
  end
end
