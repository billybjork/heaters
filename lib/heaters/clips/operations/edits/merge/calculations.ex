defmodule Heaters.Clips.Operations.Edits.Merge.Calculations do
  @moduledoc """
  Pure domain functions for merge operation calculations.
  Used by Operations.Edits.Merge for business logic.
  """

  @type merge_timeline :: %{
          new_start_frame: integer(),
          new_end_frame: integer(),
          new_start_time: float(),
          new_end_time: float(),
          total_duration: float()
        }

  @type merge_spec :: %{
          target_clip: map(),
          source_clip: map(),
          timeline: merge_timeline(),
          source_video_id: integer()
        }

  @doc """
  Calculates the timeline for merging two clips.

  The target clip provides the starting point, and the source clip is appended.

  ## Parameters
  - `target_clip`: The first clip in the merge sequence
  - `source_clip`: The second clip to be appended

  ## Returns
  - `{:ok, merge_timeline()}` with calculated timeline information
  - `{:error, String.t()}` if calculation fails
  """
  @spec calculate_merge_timeline(map(), map()) ::
          {:ok, merge_timeline()} | {:error, String.t()}
  def calculate_merge_timeline(target_clip, source_clip) do
    with :ok <- validate_clips_for_merge(target_clip, source_clip) do
      # Target clip provides the starting point
      new_start_frame = target_clip.start_frame
      new_start_time = target_clip.start_time_seconds

      # Source clip is appended, so we add its duration to target's end
      source_duration_frames = source_clip.end_frame - source_clip.start_frame
      source_duration_seconds = source_clip.end_time_seconds - source_clip.start_time_seconds

      new_end_frame = target_clip.end_frame + source_duration_frames
      new_end_time = target_clip.end_time_seconds + source_duration_seconds

      total_duration = new_end_time - new_start_time

      timeline = %{
        new_start_frame: new_start_frame,
        new_end_frame: new_end_frame,
        new_start_time: new_start_time,
        new_end_time: new_end_time,
        total_duration: total_duration
      }

      {:ok, timeline}
    end
  end

  @doc """
  Builds a merge specification containing all calculated information.

  ## Parameters
  - `target_clip`: The first clip in the merge sequence
  - `source_clip`: The second clip to be appended

  ## Returns
  - `{:ok, merge_spec()}` with complete merge specification
  - `{:error, String.t()}` if specification cannot be built
  """
  @spec build_merge_spec(map(), map()) :: {:ok, merge_spec()} | {:error, String.t()}
  def build_merge_spec(target_clip, source_clip) do
    with {:ok, timeline} <- calculate_merge_timeline(target_clip, source_clip) do
      merge_spec = %{
        target_clip: target_clip,
        source_clip: source_clip,
        timeline: timeline,
        source_video_id: target_clip.source_video_id
      }

      {:ok, merge_spec}
    end
  end

  @doc """
  Calculates the processing metadata for the merged clip.

  ## Parameters
  - `target_clip`: The target clip with existing metadata
  - `source_clip`: The source clip being merged
  - `new_identifier`: The identifier for the new merged clip

  ## Returns
  - Processing metadata map for the merged clip
  """
  @spec calculate_processing_metadata(map(), map(), String.t()) :: map()
  def calculate_processing_metadata(target_clip, source_clip, new_identifier) do
    base_metadata = target_clip.processing_metadata || %{}

    Map.merge(base_metadata, %{
      merged_from_clips: [target_clip.id, source_clip.id],
      new_identifier: new_identifier,
      merge_timestamp: DateTime.utc_now(),
      target_clip_duration: target_clip.end_time_seconds - target_clip.start_time_seconds,
      source_clip_duration: source_clip.end_time_seconds - source_clip.start_time_seconds
    })
  end

  @doc """
  Validates that the clips have the same source video for merging.

  ## Parameters
  - `target_clip`: The target clip
  - `source_clip`: The source clip

  ## Returns
  - `:ok` if clips are compatible for merging
  - `{:error, String.t()}` if clips cannot be merged
  """
  @spec validate_clips_for_merge(map(), map()) :: :ok | {:error, String.t()}
  def validate_clips_for_merge(target_clip, source_clip) do
    cond do
      target_clip.source_video_id != source_clip.source_video_id ->
        {:error, "Clips must belong to the same source video for merging"}

      target_clip.id == source_clip.id ->
        {:error, "Cannot merge a clip with itself"}

      true ->
        :ok
    end
  end

  @doc """
  Calculates merge result metadata for the result structure.

  ## Parameters
  - `merged_clip`: The newly created merged clip record
  - `target_clip_id`: ID of the target clip
  - `source_clip_id`: ID of the source clip

  ## Returns
  - Metadata map for the merge result
  """
  @spec calculate_merge_result_metadata(map(), integer(), integer()) :: map()
  def calculate_merge_result_metadata(merged_clip, target_clip_id, source_clip_id) do
    %{
      new_clip_id: merged_clip.id,
      new_duration: merged_clip.end_time_seconds - merged_clip.start_time_seconds,
      source_clips_merged: [target_clip_id, source_clip_id],
      merge_completed_at: DateTime.utc_now()
    }
  end
end
