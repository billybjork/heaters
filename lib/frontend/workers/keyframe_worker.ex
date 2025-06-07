defmodule Frontend.Workers.KeyframeWorker do
  use Oban.Worker, queue: :media_processing

  alias Frontend.Clips
  alias Frontend.PythonRunner
  alias Frontend.Workers.EmbeddingWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id, "strategy" => strategy}}) do
    try do
      clip = Clips.get_clip!(clip_id)
      handle_keyframing(clip, strategy)
    rescue
      _e in Ecto.NoResultsError ->
        # Clip was likely deleted before the job ran, which is fine.
        :ok
    end
  end

  defp handle_keyframing(%{ingest_state: "keyframed"} = _clip, _strategy), do: :ok
  defp handle_keyframing(%{ingest_state: "embedding_failed"} = _clip, _strategy), do: :ok

  defp handle_keyframing(clip, strategy) do
    Clips.update_clip(clip, %{ingest_state: "keyframing"})

    py_args = %{clip_id: clip.id, strategy: strategy}

    case PythonRunner.run("keyframe", py_args) do
      {:ok, _} ->
        Clips.update_clip(clip, %{ingest_state: "keyframed", keyframed_at: DateTime.utc_now()})

        EmbeddingWorker.new(%{
          clip_id: clip.id,
          model_name: "ViT-g-14/laion2b_s34b_b88k",
          generation_strategy: "per_keyframe_average"
        })
        |> Oban.insert()

        :ok

      {:error, reason} ->
        error_message = "Keyframe script failed: #{inspect(reason)}"
        Clips.update_clip(clip, %{ingest_state: "keyframe_failed", last_error: error_message})
        {:error, error_message}
    end
  end
end
