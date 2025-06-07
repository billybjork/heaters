defmodule Frontend.Workers.EmbeddingWorker do
  use Oban.Worker, queue: :media_processing

  alias Frontend.Clips
  alias Frontend.PythonRunner

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "clip_id" => clip_id,
          "model_name" => model_name,
          "generation_strategy" => generation_strategy
        }
      }) do
    try do
      clip = Clips.get_clip!(clip_id)
      handle_embedding(clip, model_name, generation_strategy)
    rescue
      _e in Ecto.NoResultsError ->
        # Clip was likely deleted before the job ran, which is fine.
        :ok
    end
  end

  defp handle_embedding(%{ingest_state: "embedded"}, _model, _strategy), do: :ok

  defp handle_embedding(clip, model_name, generation_strategy) do
    Clips.update_clip(clip, %{ingest_state: "embedding"})

    py_args = %{
      clip_id: clip.id,
      model_name: model_name,
      generation_strategy: generation_strategy
    }

    case PythonRunner.run("embed", py_args) do
      {:ok, _} ->
        Clips.update_clip(clip, %{
          ingest_state: "embedded",
          embedded_at: DateTime.utc_now()
        })

        :ok

      {:error, reason} ->
        error_message = "Embedding script failed: #{inspect(reason)}"

        Clips.update_clip(clip, %{
          ingest_state: "embedding_failed",
          last_error: error_message
        })

        {:error, error_message}
    end
  end
end
