defmodule Frontend.Workers.EmbeddingWorker do
  use Oban.Worker, queue: :embeddings

  alias Frontend.Clips
  alias Frontend.PythonRunner

  # Dialyzer cannot statically verify PythonRunner success paths due to external system dependencies
  @dialyzer {:nowarn_function, [perform: 1, handle_embedding: 3]}

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
    case Clips.update_clip(clip, %{ingest_state: "embedding"}) do
      {:ok, _updated_clip} ->
        py_args = %{
          clip_id: clip.id,
          model_name: model_name,
          generation_strategy: generation_strategy
        }

        case PythonRunner.run("embed", py_args) do
          {:ok, _} ->
            case Clips.update_clip(clip, %{
                   ingest_state: "embedded",
                   embedded_at: DateTime.utc_now()
                 }) do
              {:ok, _updated_clip} -> :ok
              {:error, changeset} -> {:error, "Failed to update clip as embedded: #{inspect(changeset.errors)}"}
            end

          {:error, reason} ->
            error_message = "Embedding script failed: #{inspect(reason)}"

            case Clips.update_clip(clip, %{
                   ingest_state: "embedding_failed",
                   last_error: error_message
                 }) do
              {:ok, _updated_clip} -> {:error, error_message}
              {:error, changeset} -> {:error, "Failed to update clip with error: #{inspect(changeset.errors)}"}
            end
        end

      {:error, changeset} ->
        {:error, "Failed to update clip to embedding state: #{inspect(changeset.errors)}"}
    end
  end
end
