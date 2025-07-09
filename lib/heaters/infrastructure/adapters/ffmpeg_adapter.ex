defmodule Heaters.Infrastructure.Adapters.FFmpegAdapter do
  @moduledoc """
  FFmpeg adapter providing consistent I/O interface for domain operations.

  This adapter wraps the existing Operations.Shared.FFmpegRunner module with
  standardized error handling and provides a clean interface for domain operations.
  All functions in this module perform I/O operations.
  """

  alias Heaters.Clips.Operations.Shared.FFmpegRunner

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
  Create a sprite sheet from a video file.

  ## Examples

      {:ok, file_size} = FFmpegAdapter.create_sprite_sheet(
        "/tmp/video.mp4",
        "/tmp/sprite.jpg",
        24.0,  # fps
        480,   # tile_width
        -1,    # tile_height (preserve aspect ratio)
        5,     # cols
        10     # rows
      )
  """
  @spec create_sprite_sheet(
          String.t(),
          String.t(),
          float(),
          integer(),
          integer(),
          integer(),
          integer()
        ) ::
          {:ok, integer()} | {:error, any()}
  def create_sprite_sheet(video_path, output_path, fps, tile_width, tile_height, cols, rows)
      when is_binary(video_path) and is_binary(output_path) and is_float(fps) and
             is_integer(tile_width) and is_integer(tile_height) and
             is_integer(cols) and is_integer(rows) do
    FFmpegRunner.create_sprite_sheet(
      video_path,
      output_path,
      fps,
      tile_width,
      tile_height,
      cols,
      rows
    )
  end

  @doc """
  Extract keyframes from a video at specific timestamps.

  ## Parameters
  - `video_path`: Path to the input video file
  - `output_dir`: Directory to save keyframe images
  - `timestamps`: List of timestamps in seconds to extract
  - `opts`: Optional parameters (passed to FFmpegRunner)

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

  @doc """
  Merge multiple video files into a single video.

  ## Parameters
  - `video_paths`: List of video file paths to merge
  - `output_path`: Path for the merged video file

  ## Returns
  - `{:ok, file_size}` on success
  - `{:error, reason}` on failure
  """
  @spec merge_videos([String.t()], String.t()) :: {:ok, integer()} | {:error, any()}
  def merge_videos(video_paths, output_path)
      when is_list(video_paths) and is_binary(output_path) do
    # Create a temporary concat list file
    concat_list_path = Path.join(Path.dirname(output_path), "concat_list.txt")

    try do
      # Build concat list content
      concat_content =
        video_paths
        |> Enum.map(fn path -> "file '#{path}'" end)
        |> Enum.join("\n")

      # Write concat list file
      case File.write(concat_list_path, concat_content) do
        :ok ->
          # Use FFmpegRunner to merge videos
          result = FFmpegRunner.merge_videos(concat_list_path, output_path)

          # Clean up concat list file
          File.rm(concat_list_path)

          result

        error ->
          error
      end
    rescue
      e ->
        File.rm(concat_list_path)
        {:error, "Exception during video merge: #{inspect(e)}"}
    end
  end
end
