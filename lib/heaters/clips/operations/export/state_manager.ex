defmodule Heaters.Clips.Operations.Export.StateManager do
  @moduledoc """
  State management for the export workflow.

  This module handles clip state transitions specific to the export process.
  Export converts virtual clips to physical clips using the gold master.

  ## State Flow
  - virtual clips in "review_approved" → "exporting" via `start_export_batch/1`
  - "exporting" → "exported" (is_virtual = false) via `complete_export/2`
  - any state → "export_failed" via `mark_export_failed/2`

  ## Responsibilities
  - Export-specific state transitions
  - Export failure handling with retry count
  - Batch operations for efficiency
  - Virtual to physical clip transitions
  """

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.Queries, as: ClipQueries
  require Logger

  @doc """
  Transition a batch of clips to "exporting" state.

  ## Parameters
  - `clips`: List of clip structs to transition

  ## Returns
  - `{:ok, updated_clips}` on successful transition
  - `{:error, reason}` on validation or update failure

  ## Examples

      {:ok, clips} = StateManager.start_export_batch([clip1, clip2, clip3])
      Enum.all?(clips, & &1.ingest_state == "exporting")  # true
  """
  @spec start_export_batch(list(Clip.t())) :: {:ok, list(Clip.t())} | {:error, any()}
  def start_export_batch(clips) when is_list(clips) do
    Logger.info("StateManager: Starting export for #{length(clips)} clips")

    # Validate all clips are virtual and approved
    case validate_clips_for_export(clips) do
      :ok ->
        update_clips_batch(clips, %{
          ingest_state: "exporting",
          last_error: nil
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Mark a clip as successfully exported and transition to physical.

  ## Parameters
  - `clip_id`: ID of the clip to mark as exported
  - `update_attrs`: Map containing clip_filepath and other export data

  ## Returns
  - `{:ok, updated_clip}` on successful transition
  - `{:error, reason}` if clip not found or update fails

  ## Examples

      attrs = %{
        is_virtual: false,
        clip_filepath: "final_clips/video_123_clip_001.mp4",
        ingest_state: "exported"
      }
      {:ok, clip} = StateManager.complete_export(456, attrs)
      clip.is_virtual     # false
      clip.clip_filepath  # "final_clips/video_123_clip_001.mp4"
  """
  @spec complete_export(integer(), map()) :: {:ok, Clip.t()} | {:error, any()}
  def complete_export(clip_id, update_attrs) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id) do
      final_attrs = Map.merge(update_attrs, %{
        last_error: nil
      })

      update_single_clip(clip, final_attrs)
    end
  end

  @doc """
  Mark a clip as failed during export with error details.

  ## Parameters
  - `clip_id`: ID of the clip to mark as failed
  - `error_reason`: Error reason (will be formatted as string)

  ## Returns
  - `{:ok, updated_clip}` on successful error recording
  - `{:error, reason}` if clip not found or update fails

  ## Examples

      {:ok, clip} = StateManager.mark_export_failed(456, "FFmpeg encoding failed")
      clip.ingest_state  # "export_failed"
      clip.last_error    # "FFmpeg encoding failed"
      clip.retry_count   # incremented
  """
  @spec mark_export_failed(integer(), any()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_export_failed(clip_id, error_reason) when is_integer(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id) do
      error_message = format_error_message(error_reason)

      Logger.error(
        "StateManager: Marking clip #{clip.id} as export_failed: #{error_message}"
      )

      update_single_clip(clip, %{
        ingest_state: "export_failed",
        last_error: error_message,
        retry_count: (clip.retry_count || 0) + 1
      })
    end
  end

  # Private helper functions

  defp validate_clips_for_export(clips) do
    case Enum.find(clips, &validate_single_clip_for_export/1) do
      nil -> :ok
      error -> error
    end
  end

  defp validate_single_clip_for_export(clip) do
    cond do
      not clip.is_virtual ->
        {:error, "Clip #{clip.id} is not virtual - already exported"}

      clip.ingest_state != "review_approved" ->
        {:error, "Clip #{clip.id} is not in review_approved state: #{clip.ingest_state}"}

      is_nil(clip.cut_points) ->
        {:error, "Clip #{clip.id} has no cut points"}

      true ->
        nil
    end
  end

  defp update_clips_batch(clips, attrs) do
    # Use database transaction for atomic batch update
    Repo.transaction(fn ->
      clips
      |> Enum.map(&update_single_clip(&1, attrs))
      |> handle_batch_update_results()
    end)
  end

  defp handle_batch_update_results(results) do
    {successes, errors} = Enum.split_with(results, fn
      {:ok, _} -> true
      {:error, _} -> false
    end)

    case errors do
      [] ->
        updated_clips = Enum.map(successes, fn {:ok, clip} -> clip end)
        Logger.info("StateManager: Successfully updated #{length(updated_clips)} clips")
        updated_clips

      _ ->
        error_count = length(errors)
        Logger.error("StateManager: Failed to update #{error_count} clips")
        Repo.rollback("Failed to update #{error_count} clips")
    end
  end

  defp update_single_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update()
  end

  defp format_error_message(error) when is_binary(error), do: error
  defp format_error_message(error), do: inspect(error)
end
