defmodule Heaters.Videos.Ingest do
  @moduledoc """
  Context for managing source video ingestion workflow and state transitions.
  This module handles all state management that was previously done in Python.
  """

  alias Heaters.Repo
  alias Heaters.Videos.SourceVideo
  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Clips.Clip
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

  # State transition functions for video ingestion workflow

  @doc """
  Transition a source video to "downloading" state and return updated video.
  """
  @spec start_downloading(integer()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def start_downloading(source_video_id) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id),
         :ok <- validate_state_transition(source_video.ingest_state, "downloading") do
      update_source_video(source_video, %{
        ingest_state: "downloading",
        last_error: nil
      })
    end
  end

  @doc """
  Mark a source video as successfully downloaded with metadata.
  """
  @spec complete_downloading(integer(), map()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def complete_downloading(source_video_id, metadata \\ %{}) do
    attrs = %{
      ingest_state: "downloaded",
      downloaded_at: DateTime.utc_now(),
      last_error: nil
    }

    # Add optional metadata fields
    attrs =
      attrs
      |> maybe_put(:filepath, metadata[:filepath])
      |> maybe_put(:duration_seconds, metadata[:duration_seconds])
      |> maybe_put(:fps, metadata[:fps])
      |> maybe_put(:width, metadata[:width])
      |> maybe_put(:height, metadata[:height])

    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      update_source_video(source_video, attrs)
    end
  end

  @doc """
  Transition a source video to "splicing" state.
  """
  @spec start_splicing(integer()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def start_splicing(source_video_id) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id),
         :ok <- validate_state_transition(source_video.ingest_state, "splicing") do
      update_source_video(source_video, %{
        ingest_state: "splicing",
        last_error: nil
      })
    end
  end

  @doc """
  Mark a source video as successfully spliced.
  """
  @spec complete_splicing(integer()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def complete_splicing(source_video_id) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      update_source_video(source_video, %{
        ingest_state: "spliced",
        spliced_at: DateTime.utc_now(),
        last_error: nil
      })
    end
  end

  @doc """
  Mark a source video as failed with error details.
  """
  @spec mark_failed(SourceVideo.t() | integer(), String.t(), any()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def mark_failed(source_video_or_id, failure_state, error_reason)

  def mark_failed(%SourceVideo{} = source_video, failure_state, error_reason) do
    error_message = format_error_message(error_reason)

    update_source_video(source_video, %{
      ingest_state: failure_state,
      last_error: error_message,
      retry_count: (source_video.retry_count || 0) + 1
    })
  end

  def mark_failed(source_video_id, failure_state, error_reason) when is_integer(source_video_id) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      mark_failed(source_video, failure_state, error_reason)
    end
  end

  @doc """
  Build S3 prefix for splice outputs (clips).
  """
  @spec build_s3_prefix(SourceVideo.t()) :: String.t()
  def build_s3_prefix(%SourceVideo{id: id}) do
    "source_videos/#{id}/clips"
  end

  @doc """
  Create clips from splice operation results.
  Expects clips_data to be a list of maps with clip information.
  """
  @spec create_clips_from_splice(integer(), list(map())) :: {:ok, list(Clip.t())} | {:error, any()}
  def create_clips_from_splice(source_video_id, clips_data) when is_list(clips_data) do
    Logger.info("Creating #{length(clips_data)} clips for source_video_id: #{source_video_id}")

    clips_attrs =
      clips_data
      |> Enum.with_index()
      |> Enum.map(fn {clip_data, index} ->
        build_clip_attrs(source_video_id, clip_data, index)
      end)

    case Repo.insert_all(Clip, clips_attrs, returning: true) do
      {count, clips} when count > 0 ->
        Logger.info("Successfully created #{count} clips for source_video_id: #{source_video_id}")
        {:ok, clips}

      {0, _} ->
        Logger.error("Failed to create clips for source_video_id: #{source_video_id}")
        {:error, "No clips were created"}
    end
  rescue
    e ->
      Logger.error("Error creating clips for source_video_id #{source_video_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Validate that clips data has required fields.
  """
  @spec validate_clips_data(list(map())) :: :ok | {:error, String.t()}
  def validate_clips_data(clips_data) when is_list(clips_data) do
    required_fields = [:clip_filepath, :start_time_seconds, :end_time_seconds]

    invalid_clips =
      clips_data
      |> Enum.with_index()
      |> Enum.filter(fn {clip_data, _index} ->
        not Enum.all?(required_fields, &Map.has_key?(clip_data, &1))
      end)

    if Enum.empty?(invalid_clips) do
      :ok
    else
      invalid_indices = Enum.map(invalid_clips, fn {_clip_data, index} -> index end)
      {:error, "Clips at indices #{inspect(invalid_indices)} are missing required fields: #{inspect(required_fields)}"}
    end
  end

  # Private helper functions

  defp build_clip_attrs(source_video_id, clip_data, index) do
    now = DateTime.utc_now()

    # Generate clip_identifier if not provided
    clip_identifier =
      Map.get(clip_data, :clip_identifier) ||
      "#{source_video_id}_clip_#{String.pad_leading(to_string(index + 1), 3, "0")}"

    %{
      source_video_id: source_video_id,
      clip_filepath: Map.fetch!(clip_data, :clip_filepath),
      clip_identifier: clip_identifier,
      start_frame: Map.get(clip_data, :start_frame),
      end_frame: Map.get(clip_data, :end_frame),
      start_time_seconds: Map.fetch!(clip_data, :start_time_seconds),
      end_time_seconds: Map.fetch!(clip_data, :end_time_seconds),
      ingest_state: "spliced",
      processing_metadata: Map.get(clip_data, :metadata, %{}),
      inserted_at: now,
      updated_at: now
    }
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

  defp validate_state_transition(current_state, target_state) do
    case {current_state, target_state} do
      # Valid transitions for downloading
      {"new", "downloading"} -> :ok
      {"download_failed", "downloading"} -> :ok
      {"ingestion_failed", "downloading"} -> :ok

      # Valid transitions for splicing
      {"downloaded", "splicing"} -> :ok
      {"splicing_failed", "splicing"} -> :ok

      # Invalid transitions
      _ ->
        Logger.warning("Invalid state transition from '#{current_state}' to '#{target_state}'")
        {:error, :invalid_state_transition}
    end
  end

  defp format_error_message(error_reason) when is_binary(error_reason), do: error_reason
  defp format_error_message(error_reason), do: inspect(error_reason)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
