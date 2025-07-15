defmodule Heaters.Videos.Submit do
  @moduledoc """
  Context for managing source video submit (submission) workflow.

  This module handles the initial submission of source videos, creating database records
  for URLs or file paths that will later be processed by the ingestion pipeline
  (downloading, transcoding, etc.).

  Note: "Submit" refers to accepting submissions, while "ingestion" refers to the
  actual downloading and processing done by the Python pipeline.
  """

  alias Heaters.Repo
  alias Heaters.Videos.SourceVideo
  # For more detailed error logging
  require Logger

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
    |> Enum.join(", ")
  end

  @spec submit(String.t()) :: :ok | {:error, String.t()}
  def submit(url) when is_binary(url) do
    with {:ok, _source_video} <- create_source_video(url) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_source_video(url) do
    is_http? = String.starts_with?(url, ["http://", "https://"])

    title =
      if is_http? do
        try do
          URI.parse(url).host || "?"
        rescue
          _ -> "?"
        end
      else
        url
        |> Path.basename()
        |> Path.rootname()
        |> String.slice(0, 250)
      end

    attrs = %{
      title: title,
      original_url: if(is_http?, do: url, else: nil)
    }

    %SourceVideo{}
    |> SourceVideo.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, source_video} ->
        Logger.info(
          "Successfully created source_video with ID: #{source_video.id} for URL: #{url}"
        )

        {:ok, source_video}

      {:error, changeset} ->
        Logger.error(
          "Failed to create source_video for URL '#{url}'. Changeset errors: #{inspect(changeset.errors)}"
        )

        {:error, "Validation failed: #{format_changeset_errors(changeset)}"}
    end
  rescue
    e in Postgrex.Error ->
      query_details = if Map.has_key?(e, :query), do: " query: #{e.query}", else: ""

      Logger.error(
        "Postgrex DB error during source_video create for URL '#{url}'. Error: #{Exception.message(e)}#{query_details}"
      )

      {:error, "DB error: #{Exception.message(e)}"}

    e ->
      Logger.error(
        "Generic error during source_video create for URL '#{url}'. Error: #{Exception.message(e)} Trace: #{inspect(__STACKTRACE__)}"
      )

      {:error, "DB error: #{Exception.message(e)}"}
  end

  @doc """
  Update a source video with the given attributes.
  """
  def update_source_video(%SourceVideo{} = source_video, attrs) do
    source_video
    |> SourceVideo.changeset(attrs)
    |> Repo.update()
  end
end
