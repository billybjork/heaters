defmodule Heaters.Videos.Operations.Splice.Filepaths do
  @moduledoc """
  File path utilities for splice operations.

  This module provides functions for building S3 paths and keys related to splice workflow,
  extracted from the general Ingest module to maintain clear separation of concerns.

  ## Responsibilities
  - Generate S3 paths for source videos
  - Generate S3 prefixes for clip outputs
  - Generate cache paths for scene detection results
  - Sanitize filenames for safe storage
  """

  alias Heaters.Videos.SourceVideo

  @doc """
  Build S3 key for source video storage.

  ## Parameters
  - `source_video`: SourceVideo struct with title

  ## Returns
  - String S3 key path for the source video

  ## Examples

      video = %SourceVideo{title: "My Video"}
      "source_videos/My_Video.mp4" = Filepaths.build_source_video_s3_key(video)
  """
  @spec build_source_video_s3_key(SourceVideo.t()) :: String.t()
  def build_source_video_s3_key(%SourceVideo{title: title}) do
    sanitized_title = Heaters.Utils.sanitize_filename(title)
    "source_videos/#{sanitized_title}.mp4"
  end

  @doc """
  Build S3 prefix for splice outputs (clips).

  ## Parameters
  - `source_video`: SourceVideo struct with title

  ## Returns
  - String S3 prefix for clip storage

  ## Examples

      video = %SourceVideo{title: "My Video"}
      "clips/My_Video" = Filepaths.build_clips_s3_prefix(video)
  """
  @spec build_clips_s3_prefix(SourceVideo.t()) :: String.t()
  def build_clips_s3_prefix(%SourceVideo{title: title}) do
    sanitized_title = Heaters.Utils.sanitize_filename(title)
    "clips/#{sanitized_title}"
  end

  @doc """
  Build S3 key for scene detection cache.

  ## Parameters
  - `source_video_id`: ID of the source video

  ## Returns
  - String S3 key for cached scene detection results

  ## Examples

      "scene_detection_results/123.json" = Filepaths.build_scene_cache_s3_key(123)
  """
  @spec build_scene_cache_s3_key(integer()) :: String.t()
  def build_scene_cache_s3_key(source_video_id) do
    "scene_detection_results/#{source_video_id}.json"
  end

  @doc """
  Build individual clip S3 key within a prefix.

  ## Parameters
  - `clips_prefix`: S3 prefix for the clips (from `build_clips_s3_prefix/1`)
  - `clip_identifier`: Unique identifier for the clip

  ## Returns
  - String S3 key for the individual clip

  ## Examples

      "clips/My_Video/001_clip.mp4" = Filepaths.build_clip_s3_key("clips/My_Video", "001_clip")
  """
  @spec build_clip_s3_key(String.t(), String.t()) :: String.t()
  def build_clip_s3_key(clips_prefix, clip_identifier) do
    "#{clips_prefix}/#{clip_identifier}.mp4"
  end

  @doc """
  Generate a clip identifier based on source video ID and index.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `index`: Zero-based index of the clip

  ## Returns
  - String clip identifier

  ## Examples

      "123_clip_001" = Filepaths.generate_clip_identifier(123, 0)
      "123_clip_015" = Filepaths.generate_clip_identifier(123, 14)
  """
  @spec generate_clip_identifier(integer(), non_neg_integer()) :: String.t()
  def generate_clip_identifier(source_video_id, index) do
    "#{source_video_id}_clip_#{String.pad_leading(to_string(index + 1), 3, "0")}"
  end
end
