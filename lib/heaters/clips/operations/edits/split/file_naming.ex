defmodule Heaters.Clips.Operations.Edits.Split.FileNaming do
  @moduledoc """
  Pure domain functions for split operation file naming.
  Used by Operations.Edits.Split for business logic.
  """

  alias Heaters.Utils
  alias Heaters.Clips.Operations.Edits.Split.Calculations
  alias Heaters.Clips.Operations.Shared.FileNaming

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
  - `title`: Source video title (sanitized)
  - `filename`: Filename of the split clip

  ## Returns
  - S3 key string for upload
  """
  @spec generate_s3_key(String.t(), String.t()) :: String.t()
  def generate_s3_key(title, filename) do
    FileNaming.build_split_s3_key(title, filename)
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
    metadata = %{
      original_clip_id: original_clip_id,
      file_size: file_size,
      duration_seconds: clip_segment.duration_seconds,
      segment_type: Atom.to_string(clip_segment.segment_type)
    }

    FileNaming.generate_processing_metadata(:split, metadata)
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
    FileNaming.parse_frame_numbers(filename)
  end

  @doc """
  Generates upload prefix for split clips.

  Split clips are stored in the same directory as original clips for consistency.

  ## Parameters
  - `title`: Source video title

  ## Returns
  - S3 prefix string for split clips
  """
  @spec generate_upload_prefix(String.t()) :: String.t()
  def generate_upload_prefix(title) do
    sanitized_title = FileNaming.sanitize_filename(title)
    "clips/#{sanitized_title}"
  end
end
