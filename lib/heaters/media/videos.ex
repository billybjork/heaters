defmodule Heaters.Media.Videos do
  @moduledoc """
  Core domain operations for `Heaters.Media.Video` objects.

  This module consolidates video domain operations into a single, cohesive interface.
  The actual schema definition remains in `Heaters.Media.Video`.

  ## When to Add Functions Here

  - **CRUD Operations**: Creating, reading, updating videos
  - **Domain State Management**: Video state transitions, cache upload
  - **Business Logic**: Video submission workflow, URL validation
  - **Generic Queries**: Simple state-based queries (`get_videos_by_state`)

  ## When NOT to Add Functions Here

  - **Pipeline Orchestration**: Queries for pipeline stage discovery → `Pipeline.Queries`
  - **Processing-Specific**: Single processing stage queries → respective processing modules
  - **Review Workflow**: Video review operations → `Review` context

  ## Design Philosophy

  - **Schema Separation**: `Heaters.Media.Video` defines the data structure
  - **Domain Focus**: This module provides core video business operations
  - **Pure Domain Logic**: No pipeline orchestration or workflow-specific concerns
  - **Single Import**: `alias Heaters.Media.Videos` provides access to video domain operations

  All DB interaction goes through `Heaters.Repo`, keeping "I/O at the edges".
  """

  import Ecto.Query, warn: false
  alias Heaters.Media.Video
  alias Heaters.Processing.Download.Worker, as: DownloadWorker
  alias Heaters.Repo
  require Logger

  # ---------------------------------------------------------------------------
  # CRUD Operations
  # ---------------------------------------------------------------------------

  @doc """
  Get a source video by ID.
  Returns {:ok, source_video} if found, {:error, :not_found} otherwise.
  """
  @spec get_source_video(integer()) :: {:ok, Video.t()} | {:error, :not_found}
  def get_source_video(id) do
    case Repo.get(Video, id) do
      nil -> {:error, :not_found}
      source_video -> {:ok, source_video}
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
  # State Management
  # ---------------------------------------------------------------------------

  @doc """
  Update the cache_persisted_at timestamp for a video.
  Used to mark when cache persistence process is complete.
  """
  @spec update_cache_persisted_at(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def update_cache_persisted_at(%Video{} = video) do
    import Ecto.Changeset

    video
    |> cast(%{cache_persisted_at: DateTime.utc_now()}, [:cache_persisted_at])
    |> Repo.update([])
  end

  # ---------------------------------------------------------------------------
  # Submit Operations
  # ---------------------------------------------------------------------------

  @doc """
  Submit a source video for processing.

  This function handles the initial submission of source videos, creating database records
  for URLs or file paths and immediately triggering the ingestion pipeline.

  Note: "Submit" refers to accepting submissions, while "ingestion" refers to the
  actual downloading and processing done by the Python pipeline.
  """
  @spec submit(String.t()) :: :ok | {:error, String.t()}
  def submit(url) when is_binary(url) do
    with {:ok, source_video} <- create_source_video(url),
         {:ok, _job} <- enqueue_download_job(source_video) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Query Functions - Pipeline State Management
  # ---------------------------------------------------------------------------

  @doc """
  Get all source videos with the given ingest state.
  """
  @spec get_videos_by_state(String.t()) :: [Video.t()]
  def get_videos_by_state(state) when is_binary(state) do
    from(s in Video, where: s.ingest_state == ^state)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Private Helper Functions
  # ---------------------------------------------------------------------------

  @spec enqueue_download_job(Video.t()) :: {:ok, Oban.Job.t()} | {:error, String.t()}
  defp enqueue_download_job(%Video{} = source_video) do
    job = DownloadWorker.new(%{source_video_id: source_video.id})

    case Oban.insert(job) do
      {:ok, job} ->
        Logger.info("Successfully enqueued download job for source_video ID: #{source_video.id}")

        {:ok, job}

      {:error, reason} ->
        Logger.error(
          "Failed to enqueue download job for source_video ID: #{source_video.id}. Error: #{inspect(reason)}"
        )

        {:error, "Failed to enqueue download job: #{inspect(reason)}"}
    end
  end

  @spec create_source_video(String.t()) :: {:ok, Video.t()} | {:error, String.t()}
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

  @spec format_changeset_errors(Ecto.Changeset.t()) :: String.t()
  defp format_changeset_errors(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _}} ->
      "#{field}: #{message}"
    end)
  end
end
