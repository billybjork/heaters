defmodule Frontend.Workers.SpriteWorker do
  use Oban.Worker, queue: :media_processing

  alias Frontend.Clips
  alias Frontend.PythonRunner

  @complete_states ["pending_review", "complete"]

  # Suppress Dialyzer warnings about pattern matching with PythonRunner
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

    # Idempotency check: is the clip already past the spriting stage?
    if clip.ingest_state in @complete_states or has_sprite? do
      :ok
    else
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
