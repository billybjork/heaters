defmodule Heaters.Clips.Operations.Artifacts.Sprite.VideoMetadata do
  @moduledoc """
  Pure video metadata operations for sprite generation.

  This module contains pure business logic for working with video metadata
  such as duration, FPS, and dimensions for sprite generation operations.
  No side effects or I/O operations.
  """

  @doc """
  Calculate effective FPS for operations that should not exceed video's native FPS.

  ## Examples

      iex> VideoMetadata.calculate_effective_fps(30.0, 24)
      24.0

      iex> VideoMetadata.calculate_effective_fps(15.0, 24)
      15.0

      iex> VideoMetadata.calculate_effective_fps(30.0, nil)
      30.0
  """
  @spec calculate_effective_fps(float(), integer() | float() | nil) :: float()
  def calculate_effective_fps(video_fps, nil) when is_float(video_fps) do
    video_fps
  end

  def calculate_effective_fps(video_fps, desired_fps)
      when is_float(video_fps) and (is_integer(desired_fps) or is_float(desired_fps)) do
    min(video_fps, desired_fps * 1.0)
  end

  @doc """
  Calculate total frames for a given duration and FPS.

  ## Examples

      iex> VideoMetadata.calculate_total_frames(120.0, 24.0)
      2880

      iex> VideoMetadata.calculate_total_frames(0.5, 30.0)
      15
  """
  @spec calculate_total_frames(float(), float()) :: integer()
  def calculate_total_frames(duration_seconds, fps)
      when is_float(duration_seconds) and is_float(fps) do
    ceil(duration_seconds * fps)
  end

  @doc """
  Validate that video metadata contains required fields for processing.

  ## Examples

      iex> metadata = %{duration: 120.0, fps: 30.0, width: 1920, height: 1080}
      iex> VideoMetadata.validate_metadata(metadata)
      :ok

      iex> VideoMetadata.validate_metadata(%{duration: 0.0})
      {:error, :invalid_metadata}
  """
  @spec validate_metadata(map()) :: :ok | {:error, atom()}
  def validate_metadata(metadata) when is_map(metadata) do
    required_fields = [:duration, :fps, :width, :height]

    cond do
      not has_required_fields?(metadata, required_fields) ->
        {:error, :missing_required_fields}

      not valid_duration?(metadata.duration) ->
        {:error, :invalid_duration}

      not valid_fps?(metadata.fps) ->
        {:error, :invalid_fps}

      not valid_dimensions?(metadata.width, metadata.height) ->
        {:error, :invalid_dimensions}

      true ->
        :ok
    end
  end

  @doc """
  Calculate frame positions for uniform sampling across video duration.

  ## Examples

      iex> VideoMetadata.calculate_sample_positions(120.0, 30.0, 3)
      [900, 1800, 2700]  # Frame numbers for 3 evenly spaced samples
  """
  @spec calculate_sample_positions(float(), float(), integer()) :: [integer()]
  def calculate_sample_positions(duration_seconds, fps, sample_count)
      when is_float(duration_seconds) and is_float(fps) and is_integer(sample_count) and
             sample_count > 0 do
    total_frames = calculate_total_frames(duration_seconds, fps)

    if sample_count >= total_frames do
      # If we want more samples than frames, just return all frame positions
      1..total_frames |> Enum.to_list()
    else
      # Calculate evenly spaced positions
      step = total_frames / sample_count

      1..sample_count
      |> Enum.map(fn i -> round((i - 0.5) * step) end)
      # Ensure we don't go below frame 1
      |> Enum.map(&max(1, &1))
    end
  end

  @doc """
  Calculate midpoint frame position for a video.

  ## Examples

      iex> VideoMetadata.calculate_midpoint_frame(120.0, 30.0)
      1800
  """
  @spec calculate_midpoint_frame(float(), float()) :: integer()
  def calculate_midpoint_frame(duration_seconds, fps)
      when is_float(duration_seconds) and is_float(fps) do
    total_frames = calculate_total_frames(duration_seconds, fps)
    div(total_frames, 2)
  end

  @doc """
  Check if video is long enough for meaningful processing.

  ## Examples

      iex> VideoMetadata.sufficient_duration?(5.0, 1.0)
      true

      iex> VideoMetadata.sufficient_duration?(0.5, 1.0)
      false
  """
  @spec sufficient_duration?(float(), float()) :: boolean()
  def sufficient_duration?(duration_seconds, minimum_duration)
      when is_float(duration_seconds) and is_float(minimum_duration) do
    duration_seconds >= minimum_duration
  end

  @doc """
  Extract aspect ratio from video dimensions.

  ## Examples

      iex> VideoMetadata.calculate_aspect_ratio(1920, 1080)
      1.7777777777777777

      iex> VideoMetadata.calculate_aspect_ratio(1080, 1920)  # Portrait
      0.5625
  """
  @spec calculate_aspect_ratio(integer(), integer()) :: float()
  def calculate_aspect_ratio(width, height)
      when is_integer(width) and is_integer(height) and height > 0 do
    width / height
  end

  @doc """
  Calculate tile height for sprite generation when preserving aspect ratio.

  When tile_height is -1, this function calculates the proper height based on
  the video's aspect ratio and the specified tile width.

  ## Examples

      iex> VideoMetadata.calculate_tile_height(1920, 1080, 480, -1)
      270

      iex> VideoMetadata.calculate_tile_height(1080, 1920, 480, -1)  # Portrait video
      853

      iex> VideoMetadata.calculate_tile_height(1920, 1080, 480, 200)  # Fixed height
      200
  """
  @spec calculate_tile_height(integer(), integer(), integer(), integer()) :: integer()
  def calculate_tile_height(_video_width, _video_height, _tile_width, tile_height)
      when tile_height > 0 do
    # If tile_height is already specified (not -1), return it as-is
    tile_height
  end

  def calculate_tile_height(video_width, video_height, tile_width, -1)
      when is_integer(video_width) and is_integer(video_height) and
             is_integer(tile_width) and video_width > 0 and video_height > 0 and tile_width > 0 do
    # Calculate height to preserve aspect ratio: new_height = new_width * (original_height / original_width)
    aspect_ratio = video_height / video_width
    calculated_height = round(tile_width * aspect_ratio)

    # Ensure the height is at least 1 pixel and even (for video encoding compatibility)
    max(2, calculated_height - rem(calculated_height, 2))
  end

  # Private helper functions

  defp has_required_fields?(metadata, fields) do
    Enum.all?(fields, &Map.has_key?(metadata, &1))
  end

  defp valid_duration?(duration) when is_float(duration), do: duration > 0.0
  defp valid_duration?(duration) when is_integer(duration), do: duration > 0
  defp valid_duration?(_), do: false

  defp valid_fps?(fps) when is_float(fps), do: fps > 0.0
  defp valid_fps?(fps) when is_integer(fps), do: fps > 0
  defp valid_fps?(_), do: false

  defp valid_dimensions?(width, height) when is_integer(width) and is_integer(height) do
    width > 0 and height > 0
  end

  defp valid_dimensions?(_, _), do: false
end
