defmodule Heaters.Infrastructure.Adapters.FFmpegAdapter do
  @moduledoc """
  FFmpeg adapter providing consistent I/O interface for domain operations.

  This adapter wraps the existing Operations.Shared.FFmpegRunner module with
  standardized error handling and provides a clean interface for domain operations.
  All functions in this module perform I/O operations.
  """

  alias Heaters.Clips.Shared.FFmpegRunner

  @doc """
  Get video metadata from a local video file.

  ## Examples

      {:ok, metadata} = FFmpegAdapter.get_video_metadata("/tmp/video.mp4")
      %{duration: 120.0, fps: 30.0, total_frames: 3600} = metadata
  """
  @spec get_video_metadata(String.t()) :: {:ok, map()} | {:error, any()}
  def get_video_metadata(video_path) when is_binary(video_path) do
    FFmpegRunner.get_video_metadata(video_path)
  end

  @doc """
  Create a video clip with configurable encoding profile.

  ## Parameters
  - `input_path`: Path to input video file
  - `output_path`: Path for output video clip
  - `start_time`: Start time in seconds (float)
  - `end_time`: End time in seconds (float)
  - `opts`: Optional parameters
    - `:profile` - Encoding profile to use (default: :keyframe_extraction)

  ## Returns
  - `{:ok, file_size}` on success with output file size in bytes
  - `{:error, reason}` on failure

  ## Examples

      {:ok, file_size} = FFmpegAdapter.create_video_clip("/tmp/input.mp4", "/tmp/clip.mp4", 30.0, 60.0)
      {:ok, file_size} = FFmpegAdapter.create_video_clip("/tmp/input.mp4", "/tmp/clip.mp4", 30.0, 60.0, profile: :final_export)
  """
  @spec create_video_clip(String.t(), String.t(), float(), float(), keyword()) ::
          {:ok, integer()} | {:error, any()}
  def create_video_clip(input_path, output_path, start_time, end_time, opts \\ [])
      when is_binary(input_path) and is_binary(output_path) and is_float(start_time) and
             is_float(end_time) do
    FFmpegRunner.create_video_clip(input_path, output_path, start_time, end_time, opts)
  end

  @doc """
  Extract keyframes from a video at specific timestamps.

  ## Parameters
  - `video_path`: Path to the input video file
  - `output_dir`: Directory to save keyframe images
  - `timestamps`: List of timestamps in seconds to extract
  - `opts`: Optional parameters
    - `:prefix` - Filename prefix (default: "keyframe")
    - `:quality` - JPEG quality override (uses FFmpegConfig single_frame profile by default)

  ## Returns
  - `{:ok, keyframe_data}` with list of keyframe info maps
  - `{:error, reason}` on failure

  ## Examples

      {:ok, keyframes} = FFmpegAdapter.extract_keyframes("/tmp/video.mp4", "/tmp/out", [30.0, 60.0, 90.0])
  """
  @spec extract_keyframes(String.t(), String.t(), [float()], keyword()) ::
          {:ok, [map()]} | {:error, any()}
  def extract_keyframes(video_path, output_dir, timestamps, opts \\ [])
      when is_binary(video_path) and is_binary(output_dir) and is_list(timestamps) do
    FFmpegRunner.extract_keyframes_by_timestamp(video_path, output_dir, timestamps, opts)
  end

  @doc """
  Extract keyframes from a video at specific percentage positions.

  ## Parameters
  - `video_path`: Path to the input video file
  - `output_dir`: Directory to save keyframe images
  - `percentages`: List of percentages 0.0-1.0 to extract
  - `opts`: Optional parameters (passed to FFmpegRunner)

  ## Returns
  - `{:ok, keyframe_data}` with list of keyframe info maps
  - `{:error, reason}` on failure
  """
  @spec extract_keyframes_by_percentage(String.t(), String.t(), [float()], keyword()) ::
          {:ok, [map()]} | {:error, any()}
  def extract_keyframes_by_percentage(video_path, output_dir, percentages, opts \\ [])
      when is_binary(video_path) and is_binary(output_dir) and is_list(percentages) do
    FFmpegRunner.extract_keyframes_by_percentage(video_path, output_dir, percentages, opts)
  end

  @doc """
  Extract a single keyframe at a specific timestamp.

  ## Parameters
  - `video_path`: Path to the input video file
  - `output_path`: Path for the output keyframe image
  - `timestamp`: Timestamp in seconds to extract
  - `opts`: Optional parameters (passed to FFmpegRunner)

  ## Returns
  - `{:ok, keyframe_data}` with keyframe info map
  - `{:error, reason}` on failure
  """
  @spec extract_single_keyframe(String.t(), String.t(), float(), keyword()) ::
          {:ok, map()} | {:error, any()}
  def extract_single_keyframe(video_path, output_path, timestamp, opts \\ [])
      when is_binary(video_path) and is_binary(output_path) and is_float(timestamp) do
    output_dir = Path.dirname(output_path)

    case FFmpegRunner.extract_keyframes_by_timestamp(video_path, output_dir, [timestamp], opts) do
      {:ok, [keyframe_data]} -> {:ok, keyframe_data}
      {:ok, []} -> {:error, "No keyframe extracted"}
      {:error, reason} -> {:error, reason}
    end
  end
end
