defmodule Heaters.Clips.Operations.Split.Calculations do
  @moduledoc """
  Pure split calculation functions with no side effects.
  Used by Transform.Split for business logic.
  """

  # Business configuration matching original split.py
  @min_clip_duration_seconds 0.5

  @type split_params :: %{
          split_at_frame: integer(),
          original_start_time: float(),
          original_end_time: float(),
          original_start_frame: integer(),
          original_end_frame: integer(),
          source_title: String.t(),
          fps: float(),
          source_video_id: integer()
        }

  @type clip_segment :: %{
          start_time_seconds: float(),
          end_time_seconds: float(),
          start_frame: integer(),
          end_frame: integer(),
          duration_seconds: float(),
          segment_type: :before_split | :after_split
        }

  @doc """
  Builds split parameters from clip data and split frame.

  ## Parameters
  - `clip`: Clip struct with timing and metadata
  - `split_at_frame`: Frame number where to split
  - `fps`: Video frames per second (fallback if not in metadata)

  ## Returns
  - `{:ok, split_params()}` on success
  - `{:error, String.t()}` on invalid parameters
  """
  @spec build_split_params(map(), integer(), float()) ::
          {:ok, split_params()} | {:error, String.t()}
  def build_split_params(clip, split_at_frame, fps) do
    with :ok <- validate_clip_has_source_video(clip),
         :ok <- validate_split_frame_bounds(clip, split_at_frame) do
      split_params = %{
        split_at_frame: split_at_frame,
        original_start_time: clip.start_time_seconds,
        original_end_time: clip.end_time_seconds,
        original_start_frame: clip.start_frame,
        original_end_frame: clip.end_frame,
        source_title: get_source_title(clip),
        fps: fps,
        source_video_id: clip.source_video_id
      }

      {:ok, split_params}
    end
  end

  @doc """
  Calculates the two clip segments that result from a split operation.

  ## Parameters
  - `split_params`: Split parameters with timing information

  ## Returns
  - `{:ok, {clip_segment() | nil, clip_segment() | nil}}` - May return nil for segments that are too short
  - `{:error, String.t()}` on calculation errors
  """
  @spec calculate_split_segments(split_params()) ::
          {:ok, {clip_segment() | nil, clip_segment() | nil}} | {:error, String.t()}
  def calculate_split_segments(split_params) do
    %{
      split_at_frame: split_at_frame,
      original_start_time: original_start_time,
      original_end_time: original_end_time,
      original_start_frame: original_start_frame,
      original_end_frame: original_end_frame,
      fps: fps
    } = split_params

    # Calculate split time in seconds
    split_time_abs = split_at_frame / fps

    # Segment before split point
    before_segment =
      calculate_segment_before_split(
        original_start_time,
        split_time_abs,
        original_start_frame,
        split_at_frame - 1
      )

    # Segment after split point
    after_segment =
      calculate_segment_after_split(
        split_time_abs,
        original_end_time,
        split_at_frame,
        original_end_frame
      )

    {:ok, {before_segment, after_segment}}
  end

  @doc """
  Extracts FPS from clip metadata with fallback.

  ## Parameters
  - `clip`: Clip struct with processing_metadata
  - `fallback_fps`: Default FPS if not found in metadata

  ## Returns
  - FPS as float
  """
  @spec extract_fps_from_metadata(map(), float()) :: float()
  def extract_fps_from_metadata(%{processing_metadata: metadata}, fallback_fps)
      when is_map(metadata) do
    Map.get(metadata, "fps") || Map.get(metadata, :fps) || fallback_fps
  end

  def extract_fps_from_metadata(_clip, fallback_fps), do: fallback_fps

  @doc """
  Validates that a split operation would create at least one valid clip.

  ## Parameters
  - `split_segments`: Tuple of calculated segments from calculate_split_segments/1

  ## Returns
  - `:ok` if at least one segment is valid
  - `{:error, String.t()}` if no valid segments would be created
  """
  @spec validate_split_viability({clip_segment() | nil, clip_segment() | nil}) ::
          :ok | {:error, String.t()}
  def validate_split_viability({nil, nil}) do
    {:error, "Split operation would not create any valid clips - all segments too short"}
  end

  def validate_split_viability({_segment_a, _segment_b}), do: :ok

  @doc """
  Gets the minimum clip duration threshold.

  ## Returns
  - Minimum duration in seconds as float
  """
  @spec min_clip_duration() :: float()
  def min_clip_duration, do: @min_clip_duration_seconds

  ## Private helper functions

  @spec validate_clip_has_source_video(map()) :: :ok | {:error, String.t()}
  defp validate_clip_has_source_video(%{source_video: nil}) do
    {:error, "Clip has no associated source video"}
  end

  defp validate_clip_has_source_video(%{source_video: _source_video}), do: :ok

  @spec validate_split_frame_bounds(map(), integer()) :: :ok | {:error, String.t()}
  defp validate_split_frame_bounds(
         %{start_frame: start_frame, end_frame: end_frame},
         split_at_frame
       ) do
    if split_at_frame > start_frame and split_at_frame < end_frame do
      :ok
    else
      {:error,
       "Split frame #{split_at_frame} is outside clip range (#{start_frame}-#{end_frame})"}
    end
  end

  @spec get_source_title(map()) :: String.t()
  defp get_source_title(%{source_video: %{title: title}}) when not is_nil(title) do
    title
  end

  defp get_source_title(%{source_video_id: source_video_id}) do
    "source_#{source_video_id}"
  end

  @spec calculate_segment_before_split(float(), float(), integer(), integer()) ::
          clip_segment() | nil
  defp calculate_segment_before_split(start_time, end_time, start_frame, end_frame) do
    duration = end_time - start_time

    if duration >= @min_clip_duration_seconds do
      %{
        start_time_seconds: start_time,
        end_time_seconds: end_time,
        start_frame: start_frame,
        end_frame: end_frame,
        duration_seconds: duration,
        segment_type: :before_split
      }
    else
      nil
    end
  end

  @spec calculate_segment_after_split(float(), float(), integer(), integer()) ::
          clip_segment() | nil
  defp calculate_segment_after_split(start_time, end_time, start_frame, end_frame) do
    duration = end_time - start_time

    if duration >= @min_clip_duration_seconds do
      %{
        start_time_seconds: start_time,
        end_time_seconds: end_time,
        start_frame: start_frame,
        end_frame: end_frame,
        duration_seconds: duration,
        segment_type: :after_split
      }
    else
      nil
    end
  end
end
