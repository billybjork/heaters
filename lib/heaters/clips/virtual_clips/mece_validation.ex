defmodule Heaters.Clips.VirtualClips.MeceValidation do
  @moduledoc """
  MECE (Mutually Exclusive, Collectively Exhaustive) validation for virtual clips.

  Ensures that all virtual clips for a source video maintain MECE properties:
  - Mutually Exclusive: No overlapping cut points between clips
  - Collectively Exhaustive: Complete coverage of source video with no gaps

  This module provides validation functions used by cut point operations
  to ensure data integrity and prevent coverage holes.
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Clips.Clip

  @doc """
  Validate MECE properties for all virtual clips of a source video.

  Ensures that all virtual clips for a source video are mutually exclusive,
  collectively exhaustive, with no gaps or overlaps.

  ## Parameters
  - `source_video_id`: ID of the source video to validate

  ## Returns
  - `:ok` if MECE properties are satisfied
  - `{:error, reason}` if validation fails
  """
  @spec validate_mece_for_source_video(integer()) :: :ok | {:error, String.t()}
  def validate_mece_for_source_video(source_video_id) do
    virtual_clips = get_virtual_clips_for_source(source_video_id)
    cut_points_list = Enum.map(virtual_clips, & &1.cut_points)

    with :ok <- ensure_no_overlaps(cut_points_list),
         :ok <- ensure_no_gaps(cut_points_list) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get all cut points for a source video in frame order.

  ## Parameters
  - `source_video_id`: ID of the source video

  ## Returns
  - List of frame numbers representing cut points
  """
  @spec get_cut_points_for_source_video(integer()) :: [integer()]
  def get_cut_points_for_source_video(source_video_id) do
    virtual_clips = get_virtual_clips_for_source(source_video_id)

    virtual_clips
    |> Enum.flat_map(fn clip ->
      [clip.cut_points["start_frame"], clip.cut_points["end_frame"]]
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Ensure complete coverage of source video by virtual clips.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `total_duration_seconds`: Total duration of the source video

  ## Returns
  - `:ok` if complete coverage exists
  - `{:error, reason}` if coverage is incomplete
  """
  @spec ensure_complete_coverage(integer(), float()) :: :ok | {:error, String.t()}
  def ensure_complete_coverage(source_video_id, total_duration_seconds) do
    virtual_clips = get_virtual_clips_for_source(source_video_id)
    cut_points_list = Enum.map(virtual_clips, & &1.cut_points)

    case ensure_complete_coverage_internal(cut_points_list, total_duration_seconds) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Private functions

  @spec get_virtual_clips_for_source(integer()) :: [Clip.t()]
  defp get_virtual_clips_for_source(source_video_id) do
    from(c in Clip,
      where:
        c.source_video_id == ^source_video_id and c.is_virtual == true and
          c.ingest_state != "archived",
      order_by: [asc: c.start_frame]
    )
    |> Repo.all()
  end

  @spec ensure_no_overlaps(list(map())) :: :ok | {:error, String.t()}
  defp ensure_no_overlaps(cut_points_list) do
    sorted_clips = Enum.sort_by(cut_points_list, & &1["start_frame"])

    case find_overlap_in_sorted_clips(sorted_clips) do
      nil -> :ok
      overlap -> {:error, "Overlap detected: #{inspect(overlap)}"}
    end
  end

  @spec find_overlap_in_sorted_clips(list(map())) :: map() | nil
  defp find_overlap_in_sorted_clips([]), do: nil
  defp find_overlap_in_sorted_clips([_single]), do: nil

  defp find_overlap_in_sorted_clips([first, second | rest]) do
    first_end = first["end_frame"]
    second_start = second["start_frame"]

    if first_end > second_start do
      %{
        first_clip: first,
        second_clip: second,
        overlap_frames: {second_start, first_end}
      }
    else
      find_overlap_in_sorted_clips([second | rest])
    end
  end

  @spec ensure_no_gaps(list(map())) :: :ok | {:error, String.t()}
  defp ensure_no_gaps(cut_points_list) do
    sorted_clips = Enum.sort_by(cut_points_list, & &1["start_frame"])

    case find_gap_in_sorted_clips(sorted_clips) do
      nil -> :ok
      gap -> {:error, "Gap detected: #{inspect(gap)}"}
    end
  end

  @spec find_gap_in_sorted_clips(list(map())) :: map() | nil
  defp find_gap_in_sorted_clips([]), do: nil
  defp find_gap_in_sorted_clips([_single]), do: nil

  defp find_gap_in_sorted_clips([first, second | rest]) do
    first_end = first["end_frame"]
    second_start = second["start_frame"]

    if first_end < second_start do
      %{
        first_clip: first,
        second_clip: second,
        gap_frames: {first_end, second_start}
      }
    else
      find_gap_in_sorted_clips([second | rest])
    end
  end

  @spec ensure_complete_coverage_internal(list(map()), float()) :: :ok | {:error, String.t()}
  defp ensure_complete_coverage_internal(cut_points_list, total_duration_seconds) do
    sorted_clips = Enum.sort_by(cut_points_list, & &1["start_frame"])

    case sorted_clips do
      [] ->
        {:error, "No virtual clips found"}

      clips ->
        first_clip = List.first(clips)
        last_clip = List.last(clips)

        cond do
          first_clip["start_time_seconds"] > 0.0 ->
            {:error,
             "Coverage gap at start: clips start at #{first_clip["start_time_seconds"]}s, not 0.0s"}

          last_clip["end_time_seconds"] < total_duration_seconds ->
            {:error,
             "Coverage gap at end: clips end at #{last_clip["end_time_seconds"]}s, video ends at #{total_duration_seconds}s"}

          true ->
            :ok
        end
    end
  end
end
