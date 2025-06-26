defmodule Heaters.Infrastructure.Adapters.FFmpegAdapter do
  @moduledoc """
  FFmpeg adapter providing consistent I/O interface for domain operations.

  This adapter wraps the existing Transform.Shared.FFmpegRunner module with
  standardized error handling and provides a clean interface for domain operations.
  All functions in this module perform I/O operations.
  """

  alias Heaters.Clips.Operations.Shared.FFmpegRunner

  @doc """
  Get video metadata from a local video file.

  ## Examples

      {:ok, metadata} = FFmpegAdapter.get_video_metadata("/tmp/video.mp4")
      %{duration: 120.0, fps: 30.0, width: 1920, height: 1080} = metadata
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
  Extract keyframes from a video at specific frame positions.

  ## Parameters
  - `video_path`: Path to the input video file
  - `output_dir`: Directory to save keyframe images
  - `frame_positions`: List of frame numbers to extract

  ## Returns
  - `{:ok, keyframe_paths}` with list of generated keyframe file paths
  - `{:error, reason}` on failure

  ## Examples

      {:ok, keyframe_paths} = FFmpegAdapter.extract_keyframes("/tmp/video.mp4", "/tmp/out", [100, 200, 300])
      ["keyframe_100.jpg", "keyframe_200.jpg", "keyframe_300.jpg"] = keyframe_paths
  """
  @spec extract_keyframes(String.t(), String.t(), [integer()]) ::
          {:ok, [String.t()]} | {:error, any()}
  def extract_keyframes(video_path, output_dir, frame_positions)
      when is_binary(video_path) and is_binary(output_dir) and is_list(frame_positions) do
    # NOTE: This function would need to be implemented in FFmpegRunner
    # For now, return an error indicating it's not implemented
    {:error, "Keyframe extraction not yet implemented in FFmpegRunner"}
  end

  @doc """
  Extract a single keyframe at a specific frame position.

  ## Parameters
  - `video_path`: Path to the input video file
  - `output_path`: Path for the output keyframe image
  - `frame_position`: Frame number to extract

  ## Returns
  - `{:ok, file_size}` on success
  - `{:error, reason}` on failure
  """
  @spec extract_single_keyframe(String.t(), String.t(), integer()) ::
          {:ok, integer()} | {:error, any()}
  def extract_single_keyframe(video_path, output_path, frame_position)
      when is_binary(video_path) and is_binary(output_path) and is_integer(frame_position) do
    # NOTE: This function would need to be implemented in FFmpegRunner
    # For now, return an error indicating it's not implemented
    {:error, "Single keyframe extraction not yet implemented in FFmpegRunner"}
  end

  @doc """
  Split a video at a specific frame into two parts.

  ## Parameters
  - `video_path`: Path to the input video file
  - `output_dir`: Directory to save the split video parts
  - `split_frame`: Frame number where to split the video

  ## Returns
  - `{:ok, {part1_path, part2_path}}` with paths to the two video parts
  - `{:error, reason}` on failure
  """
  @spec split_video(String.t(), String.t(), integer()) ::
          {:ok, {String.t(), String.t()}} | {:error, any()}
  def split_video(video_path, output_dir, split_frame)
      when is_binary(video_path) and is_binary(output_dir) and is_integer(split_frame) do
    # NOTE: This function would need to be implemented in FFmpegRunner
    # For now, return an error indicating it's not implemented
    {:error, "Video splitting not yet implemented in FFmpegRunner"}
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

  # NOTE: These convenience functions are temporarily commented out due to dialyzer
  # inference issues with FFmpegRunner.get_video_metadata/1. The core get_video_metadata/1
  # function works fine and is used by the domain layer.

  # @doc """
  # Get video duration in seconds.
  # Convenience function that extracts just the duration from metadata.
  # """
  # @spec get_video_duration(String.t()) :: {:ok, float()} | {:error, any()}
  # def get_video_duration(video_path) when is_binary(video_path) do
  #   case get_video_metadata(video_path) do
  #     {:ok, %{duration: duration}} when is_number(duration) -> {:ok, duration}
  #     {:ok, _metadata} -> {:error, "Duration not found in metadata"}
  #     {:error, reason} -> {:error, reason}
  #   end
  # end

  # @doc """
  # Validate that a video file can be processed by FFmpeg.
  # """
  # @spec validate_video_file(String.t()) :: :ok | {:error, any()}
  # def validate_video_file(video_path) when is_binary(video_path) do
  #   case get_video_metadata(video_path) do
  #     {:ok, metadata} ->
  #       if valid_metadata?(metadata) do
  #         :ok
  #       else
  #         {:error, "Invalid video metadata: #{inspect(metadata)}"}
  #       end
  #
  #     {:error, reason} ->
  #       {:error, reason}
  #   end
  # end

  # Private helper functions

  # NOTE: This helper function is temporarily unused due to the convenience functions
  # being commented out above. Will be re-enabled when those functions are restored.

  # defp valid_metadata?(%{duration: duration, fps: fps})
  #      when is_number(duration) and is_number(fps) and duration > 0 and fps > 0 do
  #   true
  # end

  # defp valid_metadata?(_), do: false
end
