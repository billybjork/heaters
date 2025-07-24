defmodule Heaters.Videos.Operations.DetectScenes.StateManager do
  @moduledoc """
  State management for the scene detection workflow.

  This module handles state transitions specific to the scene detection process.
  Scene detection creates virtual clips from preprocessed videos using the proxy file.

  ## State Flow
  - videos with proxy_filepath and needs_splicing = true → "scene_detection"
  - "scene_detection" → needs_splicing = false via `complete_scene_detection/1`
  - any state → "scene_detection_failed" via `mark_scene_detection_failed/2`

  ## Responsibilities
  - Scene detection state transitions
  - Scene detection failure handling with retry count
  - State validation for scene detection workflow
  """

  alias Heaters.Repo
  alias Heaters.Videos.SourceVideo
  alias Heaters.Videos.Queries, as: VideoQueries
  require Logger

  @doc """
  Transition a source video to "scene_detection" state.

  ## Parameters
  - `source_video_id`: ID of the source video to transition

  ## Returns
  - `{:ok, updated_video}` on successful transition
  - `{:error, reason}` if video not found or invalid state

  ## Examples

      {:ok, video} = StateManager.start_scene_detection(123)
      video.ingest_state  # "scene_detection"
  """
  @spec start_scene_detection(integer()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def start_scene_detection(source_video_id) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id),
         :ok <- validate_scene_detection_prerequisites(source_video) do
      update_source_video(source_video, %{
        ingest_state: "scene_detection",
        last_error: nil
      })
    end
  end

  @doc """
  Mark scene detection as complete by setting needs_splicing = false.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as complete

  ## Returns
  - `{:ok, updated_video}` on successful transition
  - `{:error, reason}` if video not found

  ## Examples

      {:ok, video} = StateManager.complete_scene_detection(123)
      video.needs_splicing  # false
  """
  @spec complete_scene_detection(integer()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def complete_scene_detection(source_video_id) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      update_source_video(source_video, %{
        ingest_state: "virtual_clips_created",
        needs_splicing: false,
        last_error: nil
      })
    end
  end

  @doc """
  Mark scene detection as complete without changing ingest_state.
  Used when virtual clips already exist but needs_splicing flag needs updating.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as complete

  ## Returns
  - `{:ok, updated_video}` on successful update
  - `{:error, reason}` if video not found
  """
  @spec mark_scene_detection_complete(integer()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def mark_scene_detection_complete(source_video_id) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      update_source_video(source_video, %{
        needs_splicing: false
      })
    end
  end

  @doc """
  Mark a source video as failed during scene detection with error details.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as failed
  - `error_reason`: Error reason (will be formatted as string)

  ## Returns
  - `{:ok, updated_video}` on successful error recording
  - `{:error, reason}` if video not found or update fails

  ## Examples

      {:ok, video} = StateManager.mark_scene_detection_failed(123, "Scene detection timeout")
      video.ingest_state    # "scene_detection_failed"
      video.last_error      # "Scene detection timeout"
      video.retry_count     # incremented
  """
  @spec mark_scene_detection_failed(integer(), any()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def mark_scene_detection_failed(source_video_id, error_reason)
      when is_integer(source_video_id) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      error_message = format_error_message(error_reason)

      Logger.error(
        "StateManager: Marking video #{source_video.id} as scene_detection_failed: #{error_message}"
      )

      update_source_video(source_video, %{
        ingest_state: "scene_detection_failed",
        last_error: error_message,
        retry_count: (source_video.retry_count || 0) + 1
      })
    end
  end

  # Private helper functions

  defp validate_scene_detection_prerequisites(source_video) do
    cond do
      is_nil(source_video.proxy_filepath) ->
        {:error, "No proxy file available - preprocessing must be completed first"}

      source_video.needs_splicing == false ->
        {:error, "Scene detection already complete (needs_splicing = false)"}

      true ->
        :ok
    end
  end

  defp update_source_video(%SourceVideo{} = source_video, attrs) do
    source_video
    |> SourceVideo.changeset(attrs)
    |> Repo.update()
  end

  defp format_error_message(error) when is_binary(error), do: error
  defp format_error_message(error), do: inspect(error)
end
