defmodule Heaters.Media.Videos do
  @moduledoc """
  All operations for `Heaters.Media.Video` domain objects.

  This module consolidates all video-related business operations (both reads and writes)
  into a single, cohesive interface. The actual schema definition remains in 
  `Heaters.Media.Video`.

  ## Design Philosophy

  - **Schema Separation**: `Heaters.Media.Video` defines the data structure
  - **Operations Consolidation**: This module (`Videos`) provides all business operations
  - **Pragmatic Approach**: Eliminates CQRS complexity while maintaining clear organization
  - **Single Import**: `alias Heaters.Media.Videos` provides access to all video operations

  ## Function Organization

  - **CRUD Operations**: Basic create, read, update functions
  - **State Management**: Pipeline state transitions and cache finalization
  - **Query Functions**: Specialized queries for pipeline stages and resumable processing
  - **Submit Operations**: Video submission and ingestion workflow

  All DB interaction goes through `Heaters.Repo`, keeping "I/O at the edges".
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Media.Video
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
  Update the cache_finalized_at timestamp for a video.
  Used to mark when cache finalization process is complete.
  """
  @spec update_cache_finalized_at(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def update_cache_finalized_at(%Video{} = video) do
    import Ecto.Changeset

    video
    |> cast(%{cache_finalized_at: DateTime.utc_now()}, [:cache_finalized_at])
    |> Repo.update([])
  end

  # ---------------------------------------------------------------------------
  # Submit Operations
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

  @doc """
  Get all source videos that need ingest processing (new, downloading, or download_failed).
  This enables resumable processing of interrupted jobs.
  """
  @spec get_videos_needing_ingest() :: [Video.t()]
  def get_videos_needing_ingest() do
    states = ["new", "downloading", "download_failed"]

    from(s in Video, where: s.ingest_state in ^states)
    |> Repo.all()
  end

  @doc """
  Get all source videos that need preprocessing (downloaded without proxy_filepath).
  This enables resumable processing of interrupted jobs.
  """
  @spec get_videos_needing_preprocessing() :: [Video.t()]
  def get_videos_needing_preprocessing() do
    from(s in Video,
      where: s.ingest_state == "downloaded" and is_nil(s.proxy_filepath)
    )
    |> Repo.all()
  end

  @doc """
  Get all source videos that need scene detection (preprocessed with needs_splicing = true).
  This enables resumable processing of interrupted jobs.
  """
  @spec get_videos_needing_scene_detection() :: [Video.t()]
  def get_videos_needing_scene_detection() do
    from(s in Video,
      where: not is_nil(s.proxy_filepath) and s.needs_splicing == true
    )
    |> Repo.all()
  end

  @doc """
  Get all source videos that need cache finalization.

  Videos need cache finalization if:
  - Scene detection is complete (needs_splicing = false)
  - Cache has not been finalized yet (cache_finalized_at is null)
  - Has files that might be cached (has filepath, proxy_filepath, or master_filepath)
  """
  @spec get_videos_needing_cache_finalization() :: [Video.t()]
  def get_videos_needing_cache_finalization() do
    from(s in Video,
      where:
        s.needs_splicing == false and
          is_nil(s.cache_finalized_at) and
          (not is_nil(s.filepath) or not is_nil(s.proxy_filepath) or not is_nil(s.master_filepath))
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Private Helper Functions
  # ---------------------------------------------------------------------------

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
    changeset.errors
    |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
    |> Enum.join(", ")
  end
end
