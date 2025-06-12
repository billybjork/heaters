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
    py_args = %{
      clip_id: clip.id,
      model_name: model_name,
      generation_strategy: generation_strategy
    }

    case PythonRunner.run("embed", py_args) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # The script itself should have recorded the error, but we'll return
        # it here to make sure Oban logs the job failure.
        {:error, reason}
    end
  end
end
