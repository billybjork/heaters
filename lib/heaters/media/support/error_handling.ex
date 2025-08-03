defmodule Heaters.Media.Support.ErrorHandling do
  @moduledoc """
  Shared error handling utilities for clip operations.

  This module provides consistent error handling across all clip operation contexts:
  - Virtual clip operations
  - Artifact generation
  - Export operations
  - General processing failures

  ## Responsibilities

  - **Failure Tracking**: `mark_failed/3` for consistent failure tracking with retry counts
  - **Error Formatting**: Standardized error message formatting
  - **State Management**: Consistent failure state transitions

  ## Usage

  Used by all operation modules for consistent error handling:

      # From virtual clip operations
      Support.ErrorHandling.mark_failed(clip_id, "virtual_operation_failed", error_reason)

      # From artifact operations
      Support.ErrorHandling.mark_failed(clip_id, "keyframe_failed", "FFmpeg error")

      # From export operations
      Support.ErrorHandling.mark_failed(clip_id, "export_failed", {:s3_error, "Upload timeout"})
  """

  alias Heaters.Repo
  alias Heaters.Media.Clip
  alias Heaters.Media.Clips
  require Logger

  @doc """
  Mark a clip transformation as failed with error tracking.

  This function is used by all transformation modules to consistently
  handle failures and track retry attempts.

  ## Parameters
  - `clip_or_id`: Either a Clip struct or clip ID integer
  - `failure_state`: The specific failure state to transition to
  - `error_reason`: The error that caused the failure

  ## Examples

      # Mark keyframe extraction as failed
      Support.ErrorHandling.mark_failed(clip_id, "keyframe_failed", "OpenCV initialization error")

      # Mark export operation as failed
      Support.ErrorHandling.mark_failed(clip, "export_failed", {:ffmpeg_error, "Invalid codec"})

      # Mark virtual clip operation as failed
      Support.ErrorHandling.mark_failed(clip_id, "virtual_operation_failed", "MECE validation error")
  """
  @spec mark_failed(Clip.t() | integer(), String.t(), any()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_failed(clip_or_id, failure_state, error_reason)

  def mark_failed(%Clip{} = clip, failure_state, error_reason) do
    error_message = format_error_message(error_reason)

    Logger.error("Marking clip #{clip.id} as failed: #{failure_state} - #{error_message}")

    update_clip(clip, %{
      ingest_state: failure_state,
      last_error: error_message,
      retry_count: (clip.retry_count || 0) + 1,
      failed_at: DateTime.utc_now()
    })
  end

  def mark_failed(clip_id, failure_state, error_reason) when is_integer(clip_id) do
    with {:ok, clip} <- Clips.get_clip(clip_id) do
      mark_failed(clip, failure_state, error_reason)
    end
  end

  @doc """
  Format error messages consistently across all operation types.

  ## Parameters
  - `error_reason`: The error to format (string, atom, tuple, or other)

  ## Returns
  - Formatted error message string

  ## Examples

      format_error_message("Simple error")
      # => "Simple error"

      format_error_message({:ffmpeg_error, "Invalid codec"})
      # => "{:ffmpeg_error, \"Invalid codec\"}"

      format_error_message(:timeout)
      # => ":timeout"
  """
  @spec format_error_message(any()) :: String.t()
  def format_error_message(error_reason) when is_binary(error_reason), do: error_reason
  def format_error_message(error_reason), do: inspect(error_reason)

  @doc """
  Check if a clip has exceeded maximum retry attempts.

  ## Parameters
  - `clip`: Clip struct with retry_count
  - `max_retries`: Maximum allowed retries (default: 3)

  ## Returns
  - `true` if clip has exceeded retry limit
  - `false` if clip can still be retried
  """
  @spec exceeded_retry_limit?(Clip.t(), integer()) :: boolean()
  def exceeded_retry_limit?(%Clip{retry_count: retry_count}, max_retries \\ 3) do
    (retry_count || 0) >= max_retries
  end

  @doc """
  Reset retry count for a clip (used when operation succeeds after failures).

  ## Parameters
  - `clip`: Clip struct to reset

  ## Returns
  - `{:ok, updated_clip}` on success
  - `{:error, reason}` on failure
  """
  @spec reset_retry_count(Clip.t()) :: {:ok, Clip.t()} | {:error, any()}
  def reset_retry_count(%Clip{} = clip) do
    update_clip(clip, %{
      retry_count: 0,
      last_error: nil,
      failed_at: nil
    })
  end

  # Private helper functions

  @spec update_clip(Clip.t(), map()) :: {:ok, Clip.t()} | {:error, any()}
  defp update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update([])
  end
end
