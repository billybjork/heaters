defmodule Heaters.Clips.Operations.Shared.FileNaming do
  @moduledoc """
  Pure file naming functions for domain operations.

  This module contains pure business logic for generating consistent,
  safe file names for various transformation operations.
  No side effects or I/O operations.
  """

  alias Heaters.Utils

  @doc """
  Generate a base filename for a clip with sanitization.

  ## Examples

      iex> FileNaming.generate_clip_base_filename(123, "sprite")
      "clip_123_sprite"

      iex> FileNaming.generate_clip_base_filename(456, "keyframe")
      "clip_456_keyframe"
  """
  @spec generate_clip_base_filename(integer(), String.t()) :: String.t()
  def generate_clip_base_filename(clip_id, operation_type)
      when is_integer(clip_id) and is_binary(operation_type) do
    clip_identifier = "clip_#{clip_id}"
    base_name = "#{clip_identifier}_#{operation_type}"
    Utils.sanitize_filename(base_name)
  end

  @doc """
  Generate a timestamp suffix for file uniqueness.

  ## Examples

      iex> timestamp = ~U[2024-01-15 10:30:45Z]
      iex> FileNaming.generate_timestamp_suffix(timestamp)
      "1705316245"
  """
  @spec generate_timestamp_suffix(DateTime.t()) :: String.t()
  def generate_timestamp_suffix(timestamp) when is_struct(timestamp, DateTime) do
    timestamp
    |> DateTime.to_unix()
    |> Integer.to_string()
  end

  @doc """
  Build S3 prefix for artifact storage.

  ## Examples

      iex> FileNaming.build_s3_prefix(123, 456, "sprites")
      "source_videos/123/clips/456/sprites"
  """
  @spec build_s3_prefix(integer(), integer(), String.t()) :: String.t()
  def build_s3_prefix(source_video_id, clip_id, artifact_type)
      when is_integer(source_video_id) and is_integer(clip_id) and is_binary(artifact_type) do
    "source_videos/#{source_video_id}/clips/#{clip_id}/#{artifact_type}"
  end

  @doc """
  Generate a complete filename with parameters and timestamp.

  ## Examples

      iex> timestamp = ~U[2024-01-15 10:30:45Z]
      iex> FileNaming.generate_filename_with_params("clip_123_sprite", %{fps: 24, width: 480}, "jpg", timestamp)
      "clip_123_sprite_24fps_w480_1705316245.jpg"
  """
  @spec generate_filename_with_params(String.t(), map(), String.t(), DateTime.t()) :: String.t()
  def generate_filename_with_params(base_name, params, extension, timestamp)
      when is_binary(base_name) and is_map(params) and is_binary(extension) and
             is_struct(timestamp, DateTime) do
    param_suffix = build_param_suffix(params)
    timestamp_suffix = generate_timestamp_suffix(timestamp)

    "#{base_name}#{param_suffix}_#{timestamp_suffix}.#{extension}"
  end

  @doc """
  Build parameter suffix from a map of parameters.
  Commonly used parameters get special formatting.

  ## Examples

      iex> FileNaming.build_param_suffix(%{fps: 24, width: 480, cols: 5})
      "_24fps_w480_c5"

      iex> FileNaming.build_param_suffix(%{strategy: "multi", count: 3})
      "_multi_count3"
  """
  @spec build_param_suffix(map()) :: String.t()
  def build_param_suffix(params) when is_map(params) do
    params
    |> Enum.map(&format_param/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  @doc """
  Ensure filename is safe for filesystem and S3.
  Delegates to Utils.sanitize_filename but provides domain-specific context.
  """
  @spec sanitize_filename(String.t()) :: String.t()
  def sanitize_filename(filename) when is_binary(filename) do
    Utils.sanitize_filename(filename)
  end

  @doc """
  Generate a unique filename that won't conflict with existing files.
  Uses timestamp and optional random suffix for uniqueness.

  ## Examples

      iex> timestamp = ~U[2024-01-15 10:30:45Z]
      iex> FileNaming.generate_unique_filename("sprite", "jpg", timestamp)
      "sprite_1705316245.jpg"

      iex> FileNaming.generate_unique_filename("sprite", "jpg", timestamp, true)
      "sprite_1705316245_a1b2c3.jpg"  # With random suffix
  """
  @spec generate_unique_filename(String.t(), String.t(), DateTime.t(), boolean()) :: String.t()
  def generate_unique_filename(base_name, extension, timestamp, add_random \\ false)
      when is_binary(base_name) and is_binary(extension) and is_struct(timestamp, DateTime) and
             is_boolean(add_random) do
    timestamp_suffix = generate_timestamp_suffix(timestamp)

    filename =
      if add_random do
        random_suffix = generate_random_suffix()
        "#{base_name}_#{timestamp_suffix}_#{random_suffix}.#{extension}"
      else
        "#{base_name}_#{timestamp_suffix}.#{extension}"
      end

    sanitize_filename(filename)
  end

  @doc """
  Extract operation type from filename if it follows naming conventions.

  ## Examples

      iex> FileNaming.extract_operation_type("clip_123_sprite_24fps_w480_1705316245.jpg")
      {:ok, "sprite"}

      iex> FileNaming.extract_operation_type("random_file.jpg")
      {:error, :unknown_pattern}
  """
  @spec extract_operation_type(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def extract_operation_type(filename) when is_binary(filename) do
    case Regex.run(~r/clip_\d+_(\w+)_/, filename) do
      [_, operation_type] -> {:ok, operation_type}
      nil -> {:error, :unknown_pattern}
    end
  end

  # Private helper functions

  defp format_param({:fps, value}) when is_number(value), do: "_#{trunc(value)}fps"
  defp format_param({:width, value}) when is_integer(value), do: "_w#{value}"
  defp format_param({:height, value}) when is_integer(value), do: "_h#{value}"
  defp format_param({:cols, value}) when is_integer(value), do: "_c#{value}"
  defp format_param({:rows, value}) when is_integer(value), do: "_r#{value}"
  defp format_param({:strategy, value}) when is_binary(value), do: "_#{value}"
  defp format_param({:count, value}) when is_integer(value), do: "_count#{value}"
  defp format_param({:frame, value}) when is_integer(value), do: "_frame#{value}"
  defp format_param(_), do: nil

  defp generate_random_suffix do
    :crypto.strong_rand_bytes(3)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 6)
  end
end
