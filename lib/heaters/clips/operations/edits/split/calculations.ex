defmodule Heaters.Clips.Operations.Edits.Split.Calculations do
  @moduledoc """
  Pure domain functions for split operation calculations.
  Used by Operations.Edits.Split for business logic.
  """

  alias Heaters.Clips.Operations.Shared.Constants
  require Logger

  @type split_params :: %{
          split_at_frame: integer(),
          clip_duration_seconds: float(),
          total_frames: integer(),
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
          segment_type: :before_split | :after_split,
          # All coordinates are clip-relative in the pure approach
          clip_relative_start: float(),
          clip_relative_end: float()
        }

  @doc """
  Builds split parameters from clip data and clip-relative split frame.

  ## Parameters
  - `clip`: Clip struct with timing and metadata
  - `split_at_frame`: Clip-relative frame number where to split (1-indexed)
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
      clip_duration_seconds = clip.end_time_seconds - clip.start_time_seconds
      # Use Float.ceil() to match frontend sprite player calculation exactly
      total_frames = Float.ceil(clip_duration_seconds * fps) |> trunc()

      split_params = %{
        split_at_frame: split_at_frame,
        clip_duration_seconds: clip_duration_seconds,
        total_frames: total_frames,
        source_title: get_source_title(clip),
        fps: fps,
        source_video_id: clip.source_video_id
      }

      {:ok, split_params}
    end
  end

  @doc """
  Calculates the two clip segments that result from a split operation.

  ## Pure Clip-Relative Approach

  This function uses pure clip-relative coordinates for simplicity and efficiency:
  1. **Frame-to-Time Conversion**: Convert clip-relative frame to clip-relative time
  2. **Segment Calculation**: Calculate both segments using clip-relative coordinates
  3. **Direct FFmpeg Usage**: All coordinates are ready for FFmpeg without conversion

  This avoids the complexity of absolute/relative conversions while maintaining efficiency
  by working directly with clip files.

  ## Parameters
  - `split_params`: Split parameters with clip-relative timing information

  ## Returns
  - `{:ok, {clip_segment() | nil, clip_segment() | nil}}` - May return nil for segments that are too short
  - `{:error, String.t()}` on calculation errors
  """
  @spec calculate_split_segments(split_params()) ::
          {:ok, {clip_segment() | nil, clip_segment() | nil}} | {:error, String.t()}
  def calculate_split_segments(split_params) do
    %{
      split_at_frame: split_at_frame,
      clip_duration_seconds: clip_duration_seconds,
      total_frames: total_frames,
      fps: fps
    } = split_params

    # Convert clip-relative frame (1-indexed) to clip-relative time
    # Frame 1 = 0.0 seconds, Frame 2 = 1/fps seconds, etc.
    split_time_relative = (split_at_frame - 1) / fps

    Logger.debug(
      "Split: Calculating segments with split_at_frame=#{split_at_frame}, fps=#{fps}, " <>
        "split_time_relative=#{split_time_relative}, clip_duration=#{clip_duration_seconds}, " <>
        "total_frames=#{total_frames}"
    )

    # Segment before split point (clip-relative coordinates)
    before_segment =
      calculate_segment_before_split(
        # Always start from beginning of clip
        0.0,
        split_time_relative,
        # First frame (1-indexed)
        1,
        # Last frame before split
        split_at_frame - 1,
        # clip_relative_start
        0.0,
        # clip_relative_end
        split_time_relative
      )

    # Segment after split point (clip-relative coordinates)
    after_segment =
      calculate_segment_after_split(
        split_time_relative,
        clip_duration_seconds,
        # First frame after split
        split_at_frame,
        # Last frame
        total_frames,
        # clip_relative_start
        split_time_relative,
        # clip_relative_end
        clip_duration_seconds
      )

    Logger.debug(
      "Split: Created segments - before: #{inspect(before_segment != nil)}, after: #{inspect(after_segment != nil)}"
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
  def min_clip_duration, do: Constants.min_clip_duration_seconds()

  @doc """
  Extracts FPS using consistent logic that matches sprite metadata generation.

  This function ensures the same FPS calculation is used across split validation,
  calculations, and sprite metadata to prevent frame indexing mismatches.

  ## Parameters
  - `clip`: Clip struct with artifacts, source video, and processing metadata

  ## Returns
  - FPS as float, using priority: sprite metadata -> source video -> processing metadata -> 30.0
  """
  @spec extract_consistent_fps(map()) :: float()
  def extract_consistent_fps(clip) do
    # Use the same FPS priority logic as sprite metadata generation
    # 1. Try sprite metadata fps (from clip artifacts)
    # 2. Try source video fps
    # 3. Try processing metadata fps
    # 4. Fallback to 30.0

    sprite_fps = extract_sprite_metadata_fps(clip)
    source_fps = extract_source_video_fps(clip)
    processing_fps = extract_fps_from_clip_fallback(clip)

    selected_fps = sprite_fps || source_fps || processing_fps || 30.0

    Logger.debug(
      "Split: FPS calculation - sprite_fps: #{inspect(sprite_fps)}, " <>
      "source_fps: #{inspect(source_fps)}, processing_fps: #{inspect(processing_fps)}, " <>
      "selected_fps: #{selected_fps}"
    )

    selected_fps
  end

  ## Private helper functions

  @spec validate_clip_has_source_video(map()) :: :ok | {:error, String.t()}
  defp validate_clip_has_source_video(%{source_video: nil}) do
    {:error, "Clip has no associated source video"}
  end

  defp validate_clip_has_source_video(%{source_video: _source_video}), do: :ok

  @spec validate_split_frame_bounds(map(), integer()) :: :ok | {:error, String.t()}
  defp validate_split_frame_bounds(clip, split_at_frame) do
    clip_duration_seconds = clip.end_time_seconds - clip.start_time_seconds

    # Use the same consistent FPS calculation as validation module
    fps = extract_consistent_fps(clip)

    # Use Float.ceil() to match frontend sprite player calculation exactly
    total_frames = Float.ceil(clip_duration_seconds * fps) |> trunc()

    # Valid range: 2 to (total_frames - 1) to prevent zero-duration segments
    min_frame = 2
    max_frame = total_frames - 1

    if split_at_frame >= min_frame and split_at_frame <= max_frame do
      :ok
    else
      {:error,
       "Split frame #{split_at_frame} is outside valid split range (#{min_frame}-#{max_frame}). " <>
         "Clip has #{total_frames} frames, but splits cannot be at frame 1 or the last frame."}
    end
  end

  @spec get_source_title(map()) :: String.t()
  defp get_source_title(%{source_video: %{title: title}}) when not is_nil(title) do
    title
  end

  defp get_source_title(%{source_video_id: source_video_id}) do
    # Use the same database lookup pattern as clip_artifacts for consistency
    alias Heaters.Videos.Queries, as: VideoQueries

    case VideoQueries.get_source_video(source_video_id) do
      {:ok, source_video} ->
        source_video.title

      {:error, _} ->
        # Fallback to ID-based structure if title lookup fails (consistent with clip_artifacts)
        "video_#{source_video_id}"
    end
  end

  @spec calculate_segment_before_split(float(), float(), integer(), integer(), float(), float()) ::
          clip_segment() | nil
  defp calculate_segment_before_split(
         start_time,
         end_time,
         start_frame,
         end_frame,
         clip_relative_start,
         clip_relative_end
       ) do
    duration = end_time - start_time

    if duration >= Constants.min_clip_duration_seconds() do
      %{
        start_time_seconds: start_time,
        end_time_seconds: end_time,
        start_frame: start_frame,
        end_frame: end_frame,
        duration_seconds: duration,
        segment_type: :before_split,
        clip_relative_start: clip_relative_start,
        clip_relative_end: clip_relative_end
      }
    else
      nil
    end
  end

  @spec calculate_segment_after_split(float(), float(), integer(), integer(), float(), float()) ::
          clip_segment() | nil
  defp calculate_segment_after_split(
         start_time,
         end_time,
         start_frame,
         end_frame,
         clip_relative_start,
         clip_relative_end
       ) do
    duration = end_time - start_time

    if duration >= Constants.min_clip_duration_seconds() do
      %{
        start_time_seconds: start_time,
        end_time_seconds: end_time,
        start_frame: start_frame,
        end_frame: end_frame,
        duration_seconds: duration,
        segment_type: :after_split,
        clip_relative_start: clip_relative_start,
        clip_relative_end: clip_relative_end
      }
    else
      nil
    end
  end

  @spec extract_sprite_metadata_fps(map()) :: float() | nil
  defp extract_sprite_metadata_fps(%{clip_artifacts: artifacts}) when is_list(artifacts) do
    # Find sprite sheet artifact and extract fps from metadata
    case Enum.find(artifacts, &(&1.artifact_type == "sprite_sheet")) do
      %{metadata: metadata} when is_map(metadata) ->
        # Try both clip_fps_source (video fps) and clip_fps (effective fps)
        # Prioritize clip_fps_source to match sprite calculation logic
        metadata["clip_fps_source"] || metadata["clip_fps"]

      _ -> nil
    end
  end

  defp extract_sprite_metadata_fps(_clip), do: nil

  @spec extract_source_video_fps(map()) :: float() | nil
  defp extract_source_video_fps(%{source_video: %{fps: fps}}) when is_number(fps) and fps > 0, do: fps * 1.0
  defp extract_source_video_fps(_clip), do: nil

  @spec extract_fps_from_clip_fallback(map()) :: float() | nil
  defp extract_fps_from_clip_fallback(%{processing_metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "fps") || Map.get(metadata, :fps) do
      fps when is_number(fps) and fps > 0 -> fps * 1.0
      _ -> nil
    end
  end

  defp extract_fps_from_clip_fallback(_clip), do: nil
end
