defmodule Heaters.Processing.Download.Core do
  @moduledoc """
  Context for managing source video download workflow and state transitions.

  This module handles the initial download phase: video submission and download.
  Splice operations are handled separately by the Videos.Operations.Splice module.

  ## State Machine Diagram (Source Video - Download Phase)

  ```
                       ┌─────────────────┐
                       │                 │
                       ▼                 │ retry
                ┌─────────────┐         │
   submit/1 ──▶ │     new     │─────────┼───────────────┐
                └──────┬──────┘         │               │
                       │                │               │
             start_downloading/1        │               │
                       │                │               │
                       ▼                │               │
                ┌─────────────┐         │               │
       ┌───────▶│ downloading │─────────┘               │
       │        └──────┬──────┘                         │
       │               │                                │
       │    complete_downloading/2                      │
       │               │                                │
       │               ▼                                │
       │        ┌─────────────┐                         │
       │        │  downloaded │◀────────────────────────┘
       │        └──────┬──────┘        (recovery)
       │               │
       │               │ (chains to Encode Worker)
       │               ▼
       │
       │ mark_failed/3
       │
       │        ┌─────────────────┐
       └────────│ download_failed │
                └─────────────────┘
  ```

  ## Full Pipeline State Flow

  ```
  Source Video States:
  ═══════════════════

  :new ──▶ :downloading ──▶ :downloaded ──▶ :encoding ──▶ :encoded
    │           │                              │             │
    │           ▼                              ▼             │
    │    :download_failed              :encoding_failed     │
    │                                                       │
    │                                                       ▼
    │                                            :detecting_scenes
    │                                                       │
    │                                                       ▼
    │                                            :detect_scenes_failed
    │                                                  OR
    │                                            :encoded (needs_splicing=false)
    │                                                       │
    └───────────────────────────────────────────────────────┘
                     (creates clips in :pending_review)
  ```

  ## State Transitions

  | From State        | To State          | Function                 | Trigger                |
  |-------------------|-------------------|--------------------------|------------------------|
  | (none)            | `:new`            | `submit/1`               | User submits URL       |
  | `:new`            | `:downloading`    | `start_downloading/1`    | Worker starts          |
  | `:downloading`    | `:downloaded`     | `complete_downloading/2` | yt-dlp + S3 done       |
  | `:downloading`    | `:download_failed`| `mark_failed/3`          | yt-dlp/S3 error        |
  | `:download_failed`| `:downloading`    | `start_downloading/1`    | Retry attempt          |
  """

  alias Heaters.Repo
  alias Heaters.Media.Video, as: SourceVideo
  alias Heaters.Media.Videos
  require Logger

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
    |> Enum.join(", ")
  end

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
  Transition a source video to :downloading state and return updated video.
  """
  @spec start_downloading(integer()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def start_downloading(source_video_id) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id),
         :ok <- validate_state_transition(source_video.ingest_state, :downloading) do
      update_source_video(source_video, %{
        ingest_state: :downloading,
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
      ingest_state: :downloaded,
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
      # Extract title from nested metadata - Python returns it as metadata.title
      |> maybe_put(:title, get_in(metadata, [:metadata, :title]))

    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      update_source_video(source_video, attrs)
    end
  end

  @doc """
  Mark a source video as failed with error details.
  """
  @spec mark_failed(SourceVideo.t() | integer(), String.t(), any()) ::
          {:ok, SourceVideo.t()} | {:error, any()}
  def mark_failed(source_video_or_id, failure_state, error_reason)

  def mark_failed(%SourceVideo{} = source_video, failure_state, error_reason) do
    error_message = format_error_message(error_reason)

    update_source_video(source_video, %{
      ingest_state: failure_state,
      last_error: error_message,
      retry_count: (source_video.retry_count || 0) + 1
    })
  end

  def mark_failed(source_video_id, failure_state, error_reason)
      when is_integer(source_video_id) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      mark_failed(source_video, failure_state, error_reason)
    end
  end

  # Private helper functions

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

    attrs = %{
      title: title,
      ingest_state: :new,
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

        {:ok, source_video.id}

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

  # Rest of private functions...
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_error_message(error) when is_binary(error), do: error
  defp format_error_message(error), do: inspect(error)

  defp validate_state_transition(current_state, target_state) do
    valid_transitions = %{
      :new => [:downloading],
      :downloading => [:downloaded, :download_failed],
      :downloaded => [:encode],
      :download_failed => [:downloading],
      :encode => [:encoded, :encode_failed],
      :encode_failed => [:encode]
    }

    case Map.get(valid_transitions, current_state) do
      nil ->
        {:error, "Invalid current state: #{current_state}"}

      allowed_states ->
        if target_state in allowed_states do
          :ok
        else
          {:error,
           "Invalid state transition from #{current_state} to #{target_state}. Allowed: #{inspect(allowed_states)}"}
        end
    end
  end

  defp update_source_video(%SourceVideo{} = source_video, attrs) do
    source_video
    |> SourceVideo.changeset(attrs)
    |> Repo.update([])
  end
end
