defmodule Heaters.Clips.Operations.Split.FileNaming do
  @moduledoc """
  Pure file naming functions for split operations.
  Used by Transform.Split for business logic.
  """

  alias Heaters.Utils
  alias Heaters.Clips.Operations.Split.Calculations

  @doc """
  Generates filename for a split clip segment.

  ## Parameters
  - `source_title`: Source video title
  - `clip_segment`: Clip segment with frame boundaries

  ## Returns
  - Sanitized filename string
  """
  @spec generate_split_filename(String.t(), Calculations.clip_segment()) :: String.t()
  def generate_split_filename(source_title, clip_segment) do
    %{start_frame: start_frame, end_frame: end_frame} = clip_segment

    sanitized_source_title = Utils.sanitize_filename(source_title)
    clip_id = "#{sanitized_source_title}_#{start_frame}_#{end_frame}"

    "#{clip_id}.mp4"
  end

  @doc """
  Generates clip identifier for a split segment.

  ## Parameters
  - `source_title`: Source video title
  - `clip_segment`: Clip segment with frame boundaries

  ## Returns
  - Sanitized clip identifier string
  """
  @spec generate_clip_identifier(String.t(), Calculations.clip_segment()) :: String.t()
  def generate_clip_identifier(source_title, clip_segment) do
    %{start_frame: start_frame, end_frame: end_frame} = clip_segment

    sanitized_source_title = Utils.sanitize_filename(source_title)
    "#{sanitized_source_title}_#{start_frame}_#{end_frame}"
  end

  @doc """
  Generates S3 key for uploading a split clip.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `filename`: Filename of the split clip

  ## Returns
  - S3 key string for upload
  """
  @spec generate_s3_key(integer(), String.t()) :: String.t()
  def generate_s3_key(source_video_id, filename) do
    "source_videos/#{source_video_id}/clips/splits/#{filename}"
  end

  @doc """
  Generates descriptive filename with segment type indicator.

  ## Parameters
  - `source_title`: Source video title
  - `clip_segment`: Clip segment with type and boundaries

  ## Returns
  - Descriptive filename with segment type
  """
  @spec generate_descriptive_filename(String.t(), Calculations.clip_segment()) :: String.t()
  def generate_descriptive_filename(source_title, clip_segment) do
    %{start_frame: start_frame, end_frame: end_frame, segment_type: segment_type} = clip_segment

    sanitized_source_title = Utils.sanitize_filename(source_title)

    segment_suffix =
      case segment_type do
        :before_split -> "part_a"
        :after_split -> "part_b"
      end

    clip_id = "#{sanitized_source_title}_#{start_frame}_#{end_frame}_#{segment_suffix}"
    "#{clip_id}.mp4"
  end

  @doc """
  Generates processing metadata for a split clip.

  ## Parameters
  - `clip_segment`: Clip segment data
  - `original_clip_id`: ID of the original clip being split
  - `file_size`: Size of the created file in bytes

  ## Returns
  - Processing metadata map
  """
  @spec generate_processing_metadata(Calculations.clip_segment(), integer(), integer()) :: map()
  def generate_processing_metadata(clip_segment, original_clip_id, file_size) do
    %{
      created_from_split: true,
      original_clip_id: original_clip_id,
      file_size: file_size,
      duration_seconds: clip_segment.duration_seconds,
      segment_type: Atom.to_string(clip_segment.segment_type)
    }
  end

  @doc """
  Parses split filename to extract frame information.

  ## Parameters
  - `filename`: Split clip filename to parse

  ## Returns
  - `{:ok, {start_frame, end_frame}}` on successful parse
  - `{:error, String.t()}` if filename format is invalid
  """
  @spec parse_split_filename(String.t()) :: {:ok, {integer(), integer()}} | {:error, String.t()}
  def parse_split_filename(filename) do
    # Remove .mp4 extension and try to extract frame numbers
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
  Generates upload prefix for split clips.

  ## Parameters
  - `source_video_id`: ID of the source video

  ## Returns
  - S3 prefix string for split clips
  """
  @spec generate_upload_prefix(integer()) :: String.t()
  def generate_upload_prefix(source_video_id) do
    "source_videos/#{source_video_id}/clips/splits"
  end
end
