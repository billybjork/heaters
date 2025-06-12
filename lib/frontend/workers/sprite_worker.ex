defmodule Frontend.Workers.SpriteWorker do
  use Oban.Worker, queue: :media_processing

  alias Frontend.Clips
  alias Frontend.PythonRunner

  @complete_states ["pending_review", "sprite_failed"]

  # Dialyzer cannot statically verify PythonRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [perform: 1, handle_sprite_generation: 1]}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id}}) do
    # Using try/rescue because get_clip! raises Ecto.NoResultsError if not found.
    try do
      clip = Clips.get_clip!(clip_id)
      handle_sprite_generation(clip)
    rescue
      _e in Ecto.NoResultsError ->
        # Clip was likely deleted before the job ran, which is fine.
        :ok
    end
  end

  defp handle_sprite_generation(clip) do
    # Idempotency check: has a sprite sheet been generated already?
    has_sprite? = Enum.any?(clip.clip_artifacts, &(&1.artifact_type == "sprite_sheet"))

    cond do
      # Already in final states - nothing to do
      clip.ingest_state in @complete_states ->
        :ok

      # Has sprite but not in final state - update state to pending_review
      has_sprite? and clip.ingest_state not in @complete_states ->
        case Clips.update_clip(clip, %{ingest_state: "pending_review"}) do
          {:ok, _updated_clip} -> :ok
          {:error, changeset} -> {:error, "Failed to update clip to pending_review: #{inspect(changeset.errors)}"}
        end

      # No sprite yet - generate it
      true ->
        # The python script will update the clip's ingest_state on both success
        # ("pending_review") and failure ("sprite_failed"), so we only need to
        # kick it off and handle the return status for Oban's sake.
        case PythonRunner.run("sprite", %{clip_id: clip.id, overwrite: false}) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            # The script itself should have recorded the error, but we'll return
            # it here to make sure Oban logs the job failure.
            {:error, reason}
        end
    end
  end
end
