defmodule Heaters.Clips.Operations.Shared.FileNaming do
  @moduledoc """
  Pure file naming functions for domain operations.

  This module contains pure business logic for generating consistent,
  safe file names for various transformation operations.
  No side effects or I/O operations.
  """

  alias Heaters.Utils
  alias Heaters.Videos.Queries, as: VideoQueries

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

      iex> FileNaming.build_s3_prefix(123, 456, "sprite_sheets")
      "clip_artifacts/Berlin_Skies_Snow_VANS/sprite_sheets"
  """
  @spec build_s3_prefix(integer(), integer(), String.t()) :: String.t()
  def build_s3_prefix(source_video_id, _clip_id, artifact_type)
      when is_integer(source_video_id) and is_binary(artifact_type) do
    # Get the source video to access the title
    case VideoQueries.get_source_video(source_video_id) do
      {:ok, source_video} ->
        sanitized_title = Heaters.Utils.sanitize_filename(source_video.title)
        "clip_artifacts/#{sanitized_title}/#{artifact_type}"

      {:error, _} ->
        # Fallback to ID-based structure if title lookup fails
        "clip_artifacts/video_#{source_video_id}/#{artifact_type}"
    end
  end

  @doc """
  Build S3 key for split clips.

  Split clips are stored in the same directory as original clips to maintain
  consistency and simplify the S3 structure. They flow through the same pipeline
  and don't need to be organizationally separated.

  ## Examples

      iex> FileNaming.build_split_s3_key("My Video", "clip_123_456.mp4")
      "clips/My_Video/clip_123_456.mp4"
  """
  @spec build_split_s3_key(String.t(), String.t()) :: String.t()
  def build_split_s3_key(title, filename) when is_binary(title) and is_binary(filename) do
    sanitized_title = sanitize_filename(title)
    "clips/#{sanitized_title}/#{filename}"
  end

  @doc """
  Build S3 key for merge clips using existing S3 path structure.

  Merge clips are placed in the same directory as the target clip, maintaining
  the existing organizational structure.

  ## Examples

      iex> target_clip = %{clip_filepath: "/clips/My_Video/original.mp4"}
      iex> FileNaming.build_merge_s3_key(target_clip, "merged_123_456.mp4")
      "clips/My_Video/merged_123_456.mp4"
  """
  @spec build_merge_s3_key(map(), String.t()) :: String.t()
  def build_merge_s3_key(target_clip, filename)
      when is_map(target_clip) and is_binary(filename) do
    output_s3_prefix =
      Path.dirname(target_clip.clip_filepath)
      |> String.trim_leading("/")

    "#{output_s3_prefix}/#{filename}"
  end

  @doc """
  Generate processing metadata for operations.

  ## Examples

      iex> FileNaming.generate_processing_metadata(:split, %{original_clip_id: 123, file_size: 1024})
      %{created_from_split: true, original_clip_id: 123, file_size: 1024}
  """
  @spec generate_processing_metadata(atom(), map()) :: map()
  def generate_processing_metadata(operation_type, metadata)
      when is_atom(operation_type) and is_map(metadata) do
    case operation_type do
      :split ->
        %{
          created_from_split: true,
          original_clip_id: metadata.original_clip_id,
          file_size: metadata.file_size,
          duration_seconds: metadata.duration_seconds,
          segment_type: metadata.segment_type
        }

      :merge ->
        base_metadata = metadata.base_metadata || %{}

        Map.merge(base_metadata, %{
          merged_from_clips: metadata.merged_from_clips,
          new_identifier: metadata.new_identifier,
          merge_timestamp: DateTime.utc_now(),
          file_size: metadata.file_size,
          target_clip_duration: metadata.target_clip_duration,
          source_clip_duration: metadata.source_clip_duration
        })

      _ ->
        metadata
    end
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

  @doc """
  Parse frame numbers from split filename.

  ## Examples

      iex> FileNaming.parse_frame_numbers("Berlin_Skies_Snow_123_456.mp4")
      {:ok, {123, 456}}

      iex> FileNaming.parse_frame_numbers("invalid_file.mp4")
      {:error, "Filename does not match split clip pattern: invalid_file.mp4"}
  """
  @spec parse_frame_numbers(String.t()) :: {:ok, {integer(), integer()}} | {:error, String.t()}
  def parse_frame_numbers(filename) when is_binary(filename) do
    base_name = String.replace(filename, ~r/\.mp4$/, "")

    case Regex.run(~r/_(\d+)_(\d+)$/, base_name) do
      [_full_match, start_frame_str, end_frame_str] ->
        try do
          start_frame = String.to_integer(start_frame_str)
          end_frame = String.to_integer(end_frame_str)
          {:ok, {start_frame, end_frame}}
        rescue
          ArgumentError ->
            {:error, "Invalid frame numbers in filename: #{filename}"}
        end

      nil ->
        {:error, "Filename does not match split clip pattern: #{filename}"}
    end
  end

  @doc """
  Parse merge filename to extract clip information.

  ## Examples

      iex> FileNaming.parse_merge_filename("merged_123_clip_456.mp4")
      {:ok, {123, "clip_456"}}

      iex> FileNaming.parse_merge_filename("invalid_file.mp4")
      {:error, "Filename does not match merge clip pattern: invalid_file.mp4"}
  """
  @spec parse_merge_filename(String.t()) :: {:ok, {integer(), String.t()}} | {:error, String.t()}
  def parse_merge_filename(filename) when is_binary(filename) do
    base_name = String.replace(filename, ~r/\.mp4$/, "")

    case Regex.run(~r/^merged_(\d+)_(.+)$/, base_name) do
      [_full_match, target_clip_id_str, source_suffix] ->
        try do
          target_clip_id = String.to_integer(target_clip_id_str)
          {:ok, {target_clip_id, source_suffix}}
        rescue
          ArgumentError ->
            {:error, "Invalid target clip ID in filename: #{filename}"}
        end

      nil ->
        {:error, "Filename does not match merge clip pattern: #{filename}"}
    end
  end

  @doc """
  Generate local download filename with prefix.

  ## Examples

      iex> clip = %{clip_filepath: "/clips/video/file.mp4"}
      iex> FileNaming.generate_local_filename(clip, "target")
      "target_file.mp4"
  """
  @spec generate_local_filename(map(), String.t()) :: String.t()
  def generate_local_filename(clip, prefix) when is_map(clip) and is_binary(prefix) do
    "#{prefix}_#{Path.basename(clip.clip_filepath)}"
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
