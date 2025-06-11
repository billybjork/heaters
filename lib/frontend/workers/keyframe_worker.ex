defmodule Frontend.Workers.KeyframeWorker do
  use Oban.Worker, queue: :media_processing

  alias Frontend.Clips
  alias Frontend.PythonRunner
  alias Frontend.Workers.EmbeddingWorker

  # Suppress Dialyzer warnings about pattern matching with PythonRunner
  @dialyzer {:nowarn_function, [perform: 1, handle_keyframing: 2]}

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
    case Clips.update_clip(clip, %{ingest_state: "keyframing"}) do
      {:ok, _updated_clip} ->
        py_args = %{clip_id: clip.id, strategy: strategy}

        case PythonRunner.run("keyframe", py_args) do
          {:ok, _} ->
            case Clips.update_clip(clip, %{ingest_state: "keyframed", keyframed_at: DateTime.utc_now()}) do
              {:ok, _updated_clip} ->
                case EmbeddingWorker.new(%{
                       clip_id: clip.id,
                       model_name: "ViT-g-14/laion2b_s34b_b88k",
                       generation_strategy: "per_keyframe_average"
                     })
                     |> Oban.insert() do
                  {:ok, _job} -> :ok
                  {:error, reason} -> {:error, "Failed to enqueue embedding worker: #{inspect(reason)}"}
                end

              {:error, changeset} ->
                {:error, "Failed to update clip as keyframed: #{inspect(changeset.errors)}"}
            end

          {:error, reason} ->
            error_message = "Keyframe script failed: #{inspect(reason)}"
            case Clips.update_clip(clip, %{ingest_state: "keyframe_failed", last_error: error_message}) do
              {:ok, _updated_clip} -> {:error, error_message}
              {:error, changeset} -> {:error, "Failed to update clip with error: #{inspect(changeset.errors)}"}
            end
        end

      {:error, changeset} ->
        {:error, "Failed to update clip to keyframing state: #{inspect(changeset.errors)}"}
    end
  end
end
