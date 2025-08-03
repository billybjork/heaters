defmodule Heaters.Media.Commands.Video do
  @moduledoc """
  WRITE-ONLY operations for `Heaters.Media.Video`.

  This module contains ONLY write operations (INSERT, UPDATE, DELETE). All database reads
  should go through `Heaters.Media.Queries.Video` to maintain proper CQRS separation.
  """

  alias Heaters.Repo
  alias Heaters.Media.Video
  require Logger

  @spec update_cache_finalized_at(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def update_cache_finalized_at(%Video{} = video) do
    import Ecto.Changeset

    video
    |> cast(%{cache_finalized_at: DateTime.utc_now()}, [:cache_finalized_at])
    |> Repo.update([])
  end

  # ---------------------------------------------------------------------------
  # Submit operations
  # ---------------------------------------------------------------------------

  @doc """
  Submit a source video for processing.

  This function handles the initial submission of source videos, creating database records
  for URLs or file paths that will later be processed by the ingestion pipeline.

  Note: "Submit" refers to accepting submissions, while "ingestion" refers to the
  actual downloading and processing done by the Python pipeline.
  """
  @spec submit(String.t()) :: :ok | {:error, String.t()}
  def submit(url) when is_binary(url) do
    with {:ok, _source_video} <- create_source_video(url) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Update a source video with the given attributes.
  """
  @spec update_source_video(Video.t(), map()) :: {:ok, Video.t()} | {:error, any()}
  def update_source_video(%Video{} = source_video, attrs) do
    source_video
    |> Video.changeset(attrs)
    |> Repo.update([])
  end

  # ---------------------------------------------------------------------------
  # Private helper functions
  # ---------------------------------------------------------------------------

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

    %Video{}
    |> Video.changeset(attrs)
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

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
    |> Enum.join(", ")
  end
end
