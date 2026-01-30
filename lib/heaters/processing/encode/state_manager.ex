defmodule Heaters.Processing.Encode.StateManager do
  @moduledoc """
  State management for the encoding workflow.

  This module handles video state transitions specific to the encoding process.
  Encoding creates master and proxy files from the source video.

  See `Heaters.Pipeline.Config` for the complete pipeline state machine diagram.

  ## State Transitions

  | From State        | To State          | Function                | Trigger                    |
  |-------------------|-------------------|-------------------------|----------------------------|
  | `:downloaded`     | `:encoding`       | `start_encoding/1`      | Encode worker starts       |
  | `:encoding`       | `:encoded`        | `complete_encoding/2`   | FFmpeg completes           |
  | `:encoding`       | `:encoding_failed`| `mark_encoding_failed/2`| FFmpeg error               |
  | `:encoding_failed`| `:encoding`       | `start_encoding/1`      | Retry attempt              |
  """

  alias Heaters.Repo
  alias Heaters.Media.Video
  alias Heaters.Media.Videos
  require Logger

  @doc """
  Transition a source video to :encoding state.

  ## Parameters
  - `source_video_id`: ID of the source video to transition

  ## Returns
  - `{:ok, updated_video}` on successful transition
  - `{:error, reason}` if video not found or invalid state transition
  """
  @spec start_encoding(integer()) :: {:ok, Video.t()} | {:error, any()}
  def start_encoding(source_video_id) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id),
         :ok <-
           validate_encoding_state_transition(source_video.ingest_state, :encoding) do
      update_source_video(source_video, %{
        ingest_state: :encoding,
        last_error: nil
      })
    end
  end

  @doc """
  Mark a source video as successfully encoded with file paths and metadata.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as encoded
  - `update_attrs`: Map containing proxy_filepath, master_filepath, keyframe_offsets, etc.

  ## Returns
  - `{:ok, updated_video}` on successful transition
  - `{:error, reason}` if video not found
  """
  @spec complete_encoding(integer(), map()) :: {:ok, Video.t()} | {:error, any()}
  def complete_encoding(source_video_id, update_attrs) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      final_attrs =
        Map.merge(update_attrs, %{
          ingest_state: :encoded,
          last_error: nil
        })

      update_source_video(source_video, final_attrs)
    end
  end

  @doc """
  Mark a source video as failed during encoding with error details.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as failed
  - `error_reason`: Error reason (will be formatted as string)

  ## Returns
  - `{:ok, updated_video}` on successful error recording
  - `{:error, reason}` if video not found or update fails
  """
  @spec mark_encoding_failed(integer(), any()) :: {:ok, Video.t()} | {:error, any()}
  def mark_encoding_failed(source_video_id, error_reason) when is_integer(source_video_id) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      error_message = format_error_message(error_reason)

      Logger.error(
        "StateManager: Marking video #{source_video.id} as encoding_failed: #{error_message}"
      )

      update_source_video(source_video, %{
        ingest_state: :encoding_failed,
        last_error: error_message,
        retry_count: source_video.retry_count + 1
      })
    end
  end

  # Private helper functions

  defp validate_encoding_state_transition(current_state, target_state) do
    valid_transitions = %{
      :downloaded => [:encoding],
      :encoding => [:encoded, :encoding_failed, :encoding],
      :encoding_failed => [:encoding]
    }

    case Map.get(valid_transitions, current_state) do
      nil ->
        {:error, "Invalid current state for encoding: #{current_state}"}

      allowed_states ->
        if target_state in allowed_states do
          :ok
        else
          {:error,
           "Invalid encoding state transition from #{current_state} to #{target_state}. Allowed: #{inspect(allowed_states)}"}
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
