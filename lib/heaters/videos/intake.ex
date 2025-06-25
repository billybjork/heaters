defmodule Heaters.Videos.Intake do
  @moduledoc """
  Context for managing source video ingestion workflow and state transitions.
  This module handles all state management that was previously done in Python.
  """

  alias Heaters.Repo
  alias Heaters.Videos.SourceVideo
  # For more detailed error logging
  require Logger

  # Ecto.Repo.insert_all takes table name as string
  @source_videos "source_videos"

  @spec submit(String.t()) :: :ok | {:error, String.t()}
  def submit(url) when is_binary(url) do
    with {:ok, _id} <- insert_source_video(url) do
      :ok
      # Propagate specific error messages
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_source_video(url) do
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

    now = DateTime.utc_now()

    fields = %{
      title: title,
      ingest_state: "new",
      original_url: if(is_http?, do: url, else: nil),
      web_scraped: is_http?,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(@source_videos, [fields], returning: [:id]) do
      {1, [%{id: id} | _]} ->
        Logger.info("Successfully inserted source_video with ID: #{id} for URL: #{url}")
        {:ok, id}

      {0, _} ->
        Logger.error(
          "DB insert_all returned 0 inserted rows for source_videos with fields: #{inspect(fields)}"
        )

        {:error, "DB insert failed: No rows inserted."}

      {_, error_info_list} ->
        Logger.error(
          "DB insert_all failed for source_videos with fields: #{inspect(fields)}. Error info: #{inspect(error_info_list)}"
        )

        {:error, "DB insert failed with errors."}
    end
  rescue
    e in Postgrex.Error ->
      query_details = if Map.has_key?(e, :query), do: " query: #{e.query}", else: ""

      Logger.error(
        "Postgrex DB error during source_video insert for URL '#{url}'. Error: #{Exception.message(e)}#{query_details}"
      )

      {:error, "DB error: #{Exception.message(e)}"}

    e ->
      Logger.error(
        # Corrected Here
        "Generic error during source_video insert for URL '#{url}'. Error: #{Exception.message(e)} Trace: #{inspect(__STACKTRACE__)}"
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
