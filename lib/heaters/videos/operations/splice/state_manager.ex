defmodule Heaters.Videos.Operations.Splice.StateManager do
  @moduledoc """
  State management for the splice workflow.

  This module handles video state transitions specific to the splicing process,
  extracted from the general Ingest module to maintain clear separation of concerns.

  ## State Flow
  - "downloaded" → "splicing" via `start_splicing/1`
  - "splicing" → "spliced" via `complete_splicing/1`
  - any state → "splicing_failed" via `mark_splicing_failed/2`

  ## Responsibilities
  - Splice-specific state transitions
  - Splice failure handling with retry count
  - State validation for splice workflow
  """

  alias Heaters.Repo
  alias Heaters.Videos.SourceVideo
  alias Heaters.Videos.Queries, as: VideoQueries
  require Logger

  @doc """
  Transition a source video to "splicing" state.

  ## Parameters
  - `source_video_id`: ID of the source video to transition

  ## Returns
  - `{:ok, updated_video}` on successful transition
  - `{:error, reason}` if video not found or invalid state transition

  ## Examples

      {:ok, video} = StateManager.start_splicing(123)
      video.ingest_state  # "splicing"
  """
  @spec start_splicing(integer()) :: {:ok, SourceVideo.t()} | {:error, any()}
  def start_splicing(source_video_id) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id),
         :ok <- validate_splice_state_transition(source_video.ingest_state, "splicing") do
      update_source_video(source_video, %{
        ingest_state: "splicing",
        last_error: nil
      })
    end
  end

  @doc """
  Mark a source video as successfully spliced.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as spliced

  ## Returns
  - `{:ok, updated_video}` on successful transition
  - `{:error, reason}` if video not found

  ## Examples

      {:ok, video} = StateManager.complete_splicing(123)
      video.ingest_state  # "spliced"
      video.spliced_at    # ~U[2023-01-01 12:00:00Z]
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
  Mark a source video as failed during splicing with error details.

  ## Parameters
  - `source_video_or_id`: SourceVideo struct or integer ID
  - `error_reason`: Error reason (will be formatted as string)

  ## Returns
  - `{:ok, updated_video}` on successful error recording
  - `{:error, reason}` if video not found or update fails

  ## Examples

      {:ok, video} = StateManager.mark_splicing_failed(123, "Scene detection failed")
      video.ingest_state  # "splicing_failed"
      video.last_error    # "Scene detection failed"
      video.retry_count   # incremented
  """
  @spec mark_splicing_failed(SourceVideo.t() | integer(), any()) ::
          {:ok, SourceVideo.t()} | {:error, any()}
  def mark_splicing_failed(source_video_or_id, error_reason)

  def mark_splicing_failed(%SourceVideo{} = source_video, error_reason) do
    error_message = format_error_message(error_reason)

    Logger.error(
      "StateManager: Marking video #{source_video.id} as splicing_failed: #{error_message}"
    )

    update_source_video(source_video, %{
      ingest_state: "splicing_failed",
      last_error: error_message,
      retry_count: (source_video.retry_count || 0) + 1
    })
  end

  def mark_splicing_failed(source_video_id, error_reason) when is_integer(source_video_id) do
    with {:ok, source_video} <- VideoQueries.get_source_video(source_video_id) do
      mark_splicing_failed(source_video, error_reason)
    end
  end

  # Private helper functions

  defp validate_splice_state_transition(current_state, target_state) do
    valid_transitions = %{
      "downloaded" => ["splicing"],
      "splicing" => ["spliced", "splicing_failed"],
      "splicing_failed" => ["splicing"]
    }

    case Map.get(valid_transitions, current_state) do
      nil ->
        {:error, "Invalid current state for splicing: #{current_state}"}

      allowed_states ->
        if target_state in allowed_states do
          :ok
        else
          {:error,
           "Invalid splice state transition from #{current_state} to #{target_state}. Allowed: #{inspect(allowed_states)}"}
        end
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
