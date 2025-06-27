defmodule Heaters.Clips.Operations.Artifacts.Sprite.FileNaming do
  @moduledoc """
  Pure sprite file naming functions with no side effects.

  This module contains business logic for generating consistent, descriptive
  file names for sprite sheets. All functions are pure.
  """

  alias Heaters.Clips.Operations.Shared.FileNaming

  @doc """
  Generate a sprite sheet filename with sprite-specific parameters.

  ## Examples

      iex> timestamp = ~U[2024-01-15 10:30:45Z]
      iex> sprite_spec = %{effective_fps: 24.0, tile_width: 480, cols: 5}
      iex> FileNaming.generate_sprite_filename(123, sprite_spec, timestamp)
      "clip_123_sprite_24fps_w480_c5_1705316245.jpg"
  """
  @spec generate_sprite_filename(integer(), map(), DateTime.t()) :: String.t()
  def generate_sprite_filename(clip_id, sprite_spec, timestamp)
      when is_integer(clip_id) and is_map(sprite_spec) and is_struct(timestamp, DateTime) do
    base_name = FileNaming.generate_clip_base_filename(clip_id, "sprite")
    sprite_params = extract_filename_params(sprite_spec)

    FileNaming.generate_filename_with_params(base_name, sprite_params, "jpg", timestamp)
  end

  @doc """
  Generate multiple sprite filenames for batch processing.

  ## Examples

      iex> timestamp = ~U[2024-01-15 10:30:45Z]
      iex> clip_ids = [123, 124, 125]
      iex> sprite_spec = %{effective_fps: 24.0, tile_width: 480, cols: 5}
      iex> FileNaming.generate_batch_sprite_filenames(clip_ids, sprite_spec, timestamp)
      [
        "clip_123_sprite_24fps_w480_c5_1705316245.jpg",
        "clip_124_sprite_24fps_w480_c5_1705316245.jpg",
        "clip_125_sprite_24fps_w480_c5_1705316245.jpg"
      ]
  """
  @spec generate_batch_sprite_filenames([integer()], map(), DateTime.t()) :: [String.t()]
  def generate_batch_sprite_filenames(clip_ids, sprite_spec, timestamp)
      when is_list(clip_ids) and is_map(sprite_spec) and is_struct(timestamp, DateTime) do
    Enum.map(clip_ids, fn clip_id ->
      generate_sprite_filename(clip_id, sprite_spec, timestamp)
    end)
  end

  @doc """
  Generate a descriptive sprite filename that includes video duration info.

  ## Examples

      iex> timestamp = ~U[2024-01-15 10:30:45Z]
      iex> sprite_spec = %{effective_fps: 24.0, tile_width: 480, cols: 5, num_frames: 2880}
      iex> video_metadata = %{duration: 120.0}
      iex> FileNaming.generate_descriptive_sprite_filename(123, sprite_spec, video_metadata, timestamp)
      "clip_123_sprite_24fps_w480_c5_120s_2880frames_1705316245.jpg"
  """
  @spec generate_descriptive_sprite_filename(integer(), map(), map(), DateTime.t()) :: String.t()
  def generate_descriptive_sprite_filename(clip_id, sprite_spec, video_metadata, timestamp)
      when is_integer(clip_id) and is_map(sprite_spec) and is_map(video_metadata) and
             is_struct(timestamp, DateTime) do
    base_name = FileNaming.generate_clip_base_filename(clip_id, "sprite")

    # Include more descriptive parameters
    params =
      sprite_spec
      |> extract_filename_params()
      |> Map.put(:duration, round(video_metadata.duration))
      |> Map.put(:frames, sprite_spec.num_frames)

    FileNaming.generate_filename_with_params(base_name, params, "jpg", timestamp)
  end

  @doc """
  Generate a compact sprite filename with minimal parameters.
  Useful when filename length needs to be kept short.

  ## Examples

      iex> timestamp = ~U[2024-01-15 10:30:45Z]
      iex> sprite_spec = %{effective_fps: 24.0, cols: 5}
      iex> FileNaming.generate_compact_sprite_filename(123, sprite_spec, timestamp)
      "clip_123_sprite_24_c5_1705316245.jpg"
  """
  @spec generate_compact_sprite_filename(integer(), map(), DateTime.t()) :: String.t()
  def generate_compact_sprite_filename(clip_id, sprite_spec, timestamp)
      when is_integer(clip_id) and is_map(sprite_spec) and is_struct(timestamp, DateTime) do
    base_name = FileNaming.generate_clip_base_filename(clip_id, "sprite")

    # Only include essential parameters for compact naming
    compact_params = %{
      fps: trunc(sprite_spec.effective_fps),
      cols: sprite_spec.cols
    }

    FileNaming.generate_filename_with_params(base_name, compact_params, "jpg", timestamp)
  end

  @doc """
  Build S3 key for sprite sheet storage.

  ## Examples

      iex> clip = %{id: 123, source_video_id: 456}
      iex> filename = "clip_123_sprite_24fps_w480_c5_1705316245.jpg"
      iex> FileNaming.build_sprite_s3_key(clip, filename)
      "source_videos/456/clips/123/sprites/clip_123_sprite_24fps_w480_c5_1705316245.jpg"
  """
  @spec build_sprite_s3_key(map(), String.t()) :: String.t()
  def build_sprite_s3_key(%{id: clip_id, source_video_id: source_video_id}, filename)
      when is_integer(clip_id) and is_integer(source_video_id) and is_binary(filename) do
    prefix = FileNaming.build_s3_prefix(source_video_id, clip_id, "sprites")
    "#{prefix}/#{filename}"
  end

  @doc """
  Parse sprite parameters from a sprite filename if it follows conventions.

  ## Examples

      iex> filename = "clip_123_sprite_24fps_w480_c5_1705316245.jpg"
      iex> FileNaming.parse_sprite_filename(filename)
      {:ok, %{clip_id: 123, fps: 24, width: 480, cols: 5, timestamp: 1705316245}}

      iex> FileNaming.parse_sprite_filename("random_file.jpg")
      {:error, :invalid_sprite_filename}
  """
  @spec parse_sprite_filename(String.t()) :: {:ok, map()} | {:error, atom()}
  def parse_sprite_filename(filename) when is_binary(filename) do
    # Pattern: clip_123_sprite_24fps_w480_c5_1705316245.jpg
    pattern = ~r/clip_(\d+)_sprite_(\d+)fps_w(\d+)_c(\d+)_(\d+)\.jpg/

    case Regex.run(pattern, filename) do
      [_, clip_id_str, fps_str, width_str, cols_str, timestamp_str] ->
        parsed = %{
          clip_id: String.to_integer(clip_id_str),
          fps: String.to_integer(fps_str),
          width: String.to_integer(width_str),
          cols: String.to_integer(cols_str),
          timestamp: String.to_integer(timestamp_str)
        }

        {:ok, parsed}

      nil ->
        {:error, :invalid_sprite_filename}
    end
  end

  @doc """
  Generate a unique sprite filename that avoids conflicts.
  Adds random suffix if collision avoidance is needed.

  ## Examples

      iex> timestamp = ~U[2024-01-15 10:30:45Z]
      iex> sprite_spec = %{effective_fps: 24.0, tile_width: 480, cols: 5}
      iex> FileNaming.generate_unique_sprite_filename(123, sprite_spec, timestamp, true)
      "clip_123_sprite_24fps_w480_c5_1705316245_a1b2c3.jpg"
  """
  @spec generate_unique_sprite_filename(integer(), map(), DateTime.t(), boolean()) :: String.t()
  def generate_unique_sprite_filename(clip_id, sprite_spec, timestamp, add_random \\ false)
      when is_integer(clip_id) and is_map(sprite_spec) and is_struct(timestamp, DateTime) and
             is_boolean(add_random) do
    base_name = FileNaming.generate_clip_base_filename(clip_id, "sprite")
    sprite_params = extract_filename_params(sprite_spec)
    param_suffix = FileNaming.build_param_suffix(sprite_params)

    sprite_base = "#{base_name}#{param_suffix}"
    FileNaming.generate_unique_filename(sprite_base, "jpg", timestamp, add_random)
  end

  @doc """
  Validate that a filename follows sprite naming conventions.

  ## Examples

      iex> FileNaming.valid_sprite_filename?("clip_123_sprite_24fps_w480_c5_1705316245.jpg")
      true

      iex> FileNaming.valid_sprite_filename?("random_file.jpg")
      false
  """
  @spec valid_sprite_filename?(String.t()) :: boolean()
  def valid_sprite_filename?(filename) when is_binary(filename) do
    case parse_sprite_filename(filename) do
      {:ok, _parsed} -> true
      {:error, _reason} -> false
    end
  end

  # Private helper functions

  defp extract_filename_params(sprite_spec) when is_map(sprite_spec) do
    %{
      fps: trunc(Map.get(sprite_spec, :effective_fps, 0)),
      width: Map.get(sprite_spec, :tile_width, 0),
      cols: Map.get(sprite_spec, :cols, 0)
    }
    |> Enum.reject(fn {_key, value} -> value == 0 end)
    |> Map.new()
  end
end
