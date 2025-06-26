defmodule Heaters.Clips.Operations.Merge.FileNaming do
  @moduledoc """
  Pure domain functions for merge operation file naming.
  Used by Operations.Merge for business logic.
  """

  alias Heaters.Utils

  @doc """
  Generates filename for a merged clip.

  ## Parameters
  - `target_clip`: The target clip being merged
  - `source_clip`: The source clip being merged

  ## Returns
  - Sanitized filename string for the merged clip
  """
  @spec generate_merge_filename(map(), map()) :: String.t()
  def generate_merge_filename(target_clip, source_clip) do
    # Extract the last part of the source filename for uniqueness
    source_suffix = extract_filename_suffix(source_clip)

    new_identifier = "merged_#{target_clip.id}_#{source_suffix}"
    sanitized_identifier = Utils.sanitize_filename(new_identifier)

    "#{sanitized_identifier}.mp4"
  end

  @doc """
  Generates clip identifier for a merged clip.

  ## Parameters
  - `target_clip`: The target clip being merged
  - `source_clip`: The source clip being merged

  ## Returns
  - Sanitized clip identifier string
  """
  @spec generate_clip_identifier(map(), map()) :: String.t()
  def generate_clip_identifier(target_clip, source_clip) do
    source_suffix = extract_filename_suffix(source_clip)
    new_identifier = "merged_#{target_clip.id}_#{source_suffix}"

    Utils.sanitize_filename(new_identifier)
  end

  @doc """
  Generates S3 key for uploading a merged clip.

  ## Parameters
  - `target_clip`: The target clip with existing S3 path
  - `filename`: Filename of the merged clip

  ## Returns
  - S3 key string for upload
  """
  @spec generate_s3_key(map(), String.t()) :: String.t()
  def generate_s3_key(target_clip, filename) do
    output_s3_prefix =
      Path.dirname(target_clip.clip_filepath)
      |> String.trim_leading("/")

    "#{output_s3_prefix}/#{filename}"
  end

  @doc """
  Generates local filename for downloading clips during merge.

  ## Parameters
  - `clip`: Clip with filepath
  - `prefix`: Prefix to distinguish target vs source ("target" or "source")

  ## Returns
  - Local filename string
  """
  @spec generate_local_filename(map(), String.t()) :: String.t()
  def generate_local_filename(clip, prefix) do
    "#{prefix}_#{Path.basename(clip.clip_filepath)}"
  end

  @doc """
  Generates FFmpeg concat list content.

  ## Parameters
  - `target_video_path`: Full path to target video file
  - `source_video_path`: Full path to source video file

  ## Returns
  - Content string for FFmpeg concat list file
  """
  @spec generate_concat_list_content(String.t(), String.t()) :: String.t()
  def generate_concat_list_content(target_video_path, source_video_path) do
    """
    file '#{Path.expand(target_video_path)}'
    file '#{Path.expand(source_video_path)}'
    """
  end

  @doc """
  Generates processing metadata for a merged clip.

  ## Parameters
  - `target_clip`: Target clip data
  - `source_clip`: Source clip data
  - `clip_identifier`: Generated identifier for the merged clip
  - `file_size`: Size of the merged file in bytes

  ## Returns
  - Processing metadata map
  """
  @spec generate_processing_metadata(map(), map(), String.t(), integer()) :: map()
  def generate_processing_metadata(target_clip, source_clip, clip_identifier, file_size) do
    base_metadata = target_clip.processing_metadata || %{}

    Map.merge(base_metadata, %{
      merged_from_clips: [target_clip.id, source_clip.id],
      new_identifier: clip_identifier,
      merge_timestamp: DateTime.utc_now(),
      file_size: file_size,
      target_clip_duration: target_clip.end_time_seconds - target_clip.start_time_seconds,
      source_clip_duration: source_clip.end_time_seconds - source_clip.start_time_seconds
    })
  end

  @doc """
  Parses merge filename to extract original clip information.

  ## Parameters
  - `filename`: Merge clip filename to parse

  ## Returns
  - `{:ok, {target_clip_id, source_suffix}}` on successful parse
  - `{:error, String.t()}` if filename format is invalid
  """
  @spec parse_merge_filename(String.t()) :: {:ok, {integer(), String.t()}} | {:error, String.t()}
  def parse_merge_filename(filename) do
    # Remove .mp4 extension and try to extract merge information
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

  ## Private helper functions

  @spec extract_filename_suffix(map()) :: String.t()
  defp extract_filename_suffix(%{clip_filepath: filepath}) do
    Path.basename(filepath, ".mp4")
    |> String.split("_")
    |> List.last()
    |> case do
      nil -> "clip"
      suffix -> suffix
    end
  end
end
