defmodule Heaters.Processing.Preprocess.StateManager do
  @moduledoc """
  State management for the preprocessing workflow.

  This module handles video state transitions specific to the preprocessing process.
  Preprocessing creates master and proxy files from the source video.

  ## State Flow
  - "downloaded" → "preprocessing" via `start_preprocessing/1`
  - "preprocessing" → "preprocessed" via `complete_preprocessing/2`
  - any state → "preprocessing_failed" via `mark_preprocessing_failed/2`

  ## Responsibilities
  - Preprocessing-specific state transitions
  - Preprocessing failure handling with retry count
  - State validation for preprocessing workflow
  """

  alias Heaters.Repo
  alias Heaters.Media.Video
  alias Heaters.Media.Videos
  require Logger

  @doc """
  Transition a source video to "preprocessing" state.

  ## Parameters
  - `source_video_id`: ID of the source video to transition

  ## Returns
  - `{:ok, updated_video}` on successful transition
  - `{:error, reason}` if video not found or invalid state transition

  ## Examples

      {:ok, video} = StateManager.start_preprocessing(123)
      video.ingest_state  # "preprocessing"
  """
  @spec start_preprocessing(integer()) :: {:ok, Video.t()} | {:error, any()}
  def start_preprocessing(source_video_id) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id),
         :ok <-
           validate_preprocessing_state_transition(source_video.ingest_state, "preprocessing") do
      update_source_video(source_video, %{
        ingest_state: "preprocessing",
        last_error: nil
      })
    end
  end

  @doc """
  Mark a source video as successfully preprocessed with file paths and metadata.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as preprocessed
  - `update_attrs`: Map containing proxy_filepath, master_filepath, keyframe_offsets, etc.

  ## Returns
  - `{:ok, updated_video}` on successful transition
  - `{:error, reason}` if video not found

  ## Examples

      attrs = %{
        proxy_filepath: "review_proxies/video_123_proxy.mp4",
        master_filepath: "masters/video_123_master.mkv",
        keyframe_offsets: [0, 1500, 3000]
      }
      {:ok, video} = StateManager.complete_preprocessing(123, attrs)
      video.ingest_state  # "preprocessed"
  """
  @spec complete_preprocessing(integer(), map()) :: {:ok, Video.t()} | {:error, any()}
  def complete_preprocessing(source_video_id, update_attrs) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      final_attrs =
        Map.merge(update_attrs, %{
          ingest_state: "preprocessed",
          last_error: nil
        })

      update_source_video(source_video, final_attrs)
    end
  end

  @doc """
  Mark a source video as failed during preprocessing with error details.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as failed
  - `error_reason`: Error reason (will be formatted as string)

  ## Returns
  - `{:ok, updated_video}` on successful error recording
  - `{:error, reason}` if video not found or update fails

  ## Examples

      {:ok, video} = StateManager.mark_preprocessing_failed(123, "FFmpeg encoding failed")
      video.ingest_state  # "preprocessing_failed"
      video.last_error    # "FFmpeg encoding failed"
      video.retry_count   # incremented
  """
  @spec mark_preprocessing_failed(integer(), any()) :: {:ok, Video.t()} | {:error, any()}
  def mark_preprocessing_failed(source_video_id, error_reason) when is_integer(source_video_id) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      error_message = format_error_message(error_reason)

      Logger.error(
        "StateManager: Marking video #{source_video.id} as preprocessing_failed: #{error_message}"
      )

      update_source_video(source_video, %{
        ingest_state: "preprocessing_failed",
        last_error: error_message,
        retry_count: (source_video.retry_count || 0) + 1
      })
    end
  end

  # Private helper functions

  defp validate_preprocessing_state_transition(current_state, target_state) do
    valid_transitions = %{
      "downloaded" => ["preprocessing"],
      "preprocessing" => ["preprocessed", "preprocessing_failed"],
      "preprocessing_failed" => ["preprocessing"]
    }

    case Map.get(valid_transitions, current_state) do
      nil ->
        {:error, "Invalid current state for preprocessing: #{current_state}"}

      allowed_states ->
        if target_state in allowed_states do
          :ok
        else
          {:error,
           "Invalid preprocessing state transition from #{current_state} to #{target_state}. Allowed: #{inspect(allowed_states)}"}
        end
    end
  end

  defp update_source_video(%Video{} = source_video, attrs) do
    source_video
    |> Video.changeset(attrs)
    |> Repo.update([])
  end

  defp format_error_message(error) when is_binary(error), do: error
  defp format_error_message(error), do: inspect(error)
end
