defmodule Heaters.Storage.S3Paths do
  @moduledoc """
  Centralized S3 path generation for the Heaters video processing pipeline.

  This module is the single source of truth for all S3 path generation, eliminating
  coupling between Elixir and Python components. All S3 paths are generated here
  and passed to Python tasks as parameters.

  ## Design Principles

  - **Single Source of Truth**: All S3 directory structure defined here
  - **Consistent Sanitization**: Uses unified filename sanitization logic
  - **Validation**: Ensures generated paths are valid S3 keys
  - **Documentation**: Clear examples and purpose for each path type

  ## S3 Directory Structure

  ```
  s3://bucket/
  ├── originals/          # Downloaded source videos
  ├── masters/            # High-quality H.264 archival videos
  ├── proxies/            # Review-optimized videos (720p, CRF 28)
  ├── final_clips/        # Exported clips ready for delivery
  └── artifacts/          # Keyframes, thumbnails, and other assets
      ├── keyframes/
      └── thumbnails/
  ```

  ## Usage

      # Generate paths for video processing
      paths = S3Paths.generate_video_paths(video_id, title)

      # Generate paths for clip export
      clip_path = S3Paths.generate_clip_path(clip_id, title, identifier)

      # Generate paths for artifacts
      artifact_path = S3Paths.generate_artifact_path(clip_id, :keyframe, "frame_001.jpg")

  All functions in this module are pure functions that generate paths without side effects.
  """

  alias Heaters.Utils

  @max_filename_length 100

  # S3 folder structure constants
  @originals_folder "originals"
  @masters_folder "masters"
  @proxies_folder "proxies"
  @final_clips_folder "final_clips"
  @artifacts_folder "artifacts"
  @keyframes_subfolder "keyframes"
  @thumbnails_subfolder "thumbnails"

  @doc """
  Generates a complete set of video processing paths for a source video.

  Returns a map with all the paths needed for video processing pipeline stages.

  ## Parameters
  - `video_id`: Integer ID of the source video
  - `title`: Video title for filename generation
  - `timestamp`: Optional timestamp for uniqueness (defaults to current UTC)

  ## Returns
  Map with keys:
  - `:original` - Path for downloaded source video
  - `:master` - Path for high-quality archival video
  - `:proxy` - Path for review-optimized video

  ## Examples

      iex> S3Paths.generate_video_paths(123, "My Video Title")
      %{
        original: "originals/My_Video_Title_20240115_143022.mp4",
        master: "masters/My_Video_Title_123_master.mp4",
        proxy: "proxies/My_Video_Title_123_proxy.mp4"
      }
  """
  @spec generate_video_paths(integer(), String.t(), String.t() | nil) :: %{
          original: String.t(),
          master: String.t(),
          proxy: String.t()
        }
  def generate_video_paths(video_id, title, timestamp \\ nil) do
    sanitized_title = sanitize_title(title)
    timestamp_str = timestamp || generate_timestamp()

    %{
      original: generate_original_path(sanitized_title, timestamp_str),
      master: generate_master_path(sanitized_title, video_id),
      proxy: generate_proxy_path(sanitized_title, video_id)
    }
  end

  @doc """
  Generates S3 path for original source video (from download).

  ## Parameters
  - `title`: Video title for filename generation
  - `timestamp`: Timestamp string for uniqueness
  - `extension`: File extension (default: ".mp4")

  ## Examples

      iex> S3Paths.generate_original_path("My Video", "20240115_143022", ".mp4")
      "originals/My_Video_20240115_143022.mp4"
  """
  @spec generate_original_path(String.t(), String.t(), String.t()) :: String.t()
  def generate_original_path(title, timestamp, extension \\ ".mp4") do
    sanitized_title = sanitize_title(title)
    "#{@originals_folder}/#{sanitized_title}_#{timestamp}#{extension}"
  end

  @doc """
  Generates S3 path for master archival video.

  ## Parameters
  - `title`: Video title for filename generation
  - `video_id`: Source video ID for uniqueness

  ## Examples

      iex> S3Paths.generate_master_path("My Video", 123)
      "masters/My_Video_123_master.mp4"
  """
  @spec generate_master_path(String.t(), integer()) :: String.t()
  def generate_master_path(title, video_id) do
    sanitized_title = sanitize_title(title)
    "#{@masters_folder}/#{sanitized_title}_#{video_id}_master.mp4"
  end

  @doc """
  Generates S3 path for proxy video (review UI).

  ## Parameters
  - `title`: Video title for filename generation
  - `video_id`: Source video ID for uniqueness

  ## Examples

      iex> S3Paths.generate_proxy_path("My Video", 123)
      "proxies/My_Video_123_proxy.mp4"
  """
  @spec generate_proxy_path(String.t(), integer()) :: String.t()
  def generate_proxy_path(title, video_id) do
    sanitized_title = sanitize_title(title)
    "#{@proxies_folder}/#{sanitized_title}_#{video_id}_proxy.mp4"
  end

  @doc """
  Generates S3 path for exported clip.

  ## Parameters
  - `clip_id`: Clip ID for uniqueness
  - `title`: Video title for filename generation
  - `identifier`: Clip identifier (e.g., "clip_001")

  ## Examples

      iex> S3Paths.generate_clip_path(456, "My Video", "clip_001")
      "final_clips/My_Video_clip_001.mp4"
  """
  @spec generate_clip_path(integer(), String.t(), String.t()) :: String.t()
  def generate_clip_path(_clip_id, title, identifier) do
    sanitized_title = sanitize_title(title)
    sanitized_identifier = sanitize_filename(identifier)
    "#{@final_clips_folder}/#{sanitized_title}_#{sanitized_identifier}.mp4"
  end

  @doc """
  Generates S3 path for clip artifact (keyframes, thumbnails, etc.).

  ## Parameters
  - `clip_id`: Clip ID for organization
  - `artifact_type`: Type of artifact (:keyframe, :thumbnail, :etc)
  - `filename`: Base filename for the artifact

  ## Examples

      iex> S3Paths.generate_artifact_path(456, :keyframe, "frame_001.jpg")
      "artifacts/keyframes/clip_456_frame_001.jpg"

      iex> S3Paths.generate_artifact_path(789, :thumbnail, "thumb.jpg")
      "artifacts/thumbnails/clip_789_thumb.jpg"
  """
  @spec generate_artifact_path(integer(), atom(), String.t()) :: String.t()
  def generate_artifact_path(clip_id, artifact_type, filename) do
    sanitized_filename = sanitize_filename(filename)
    subfolder = get_artifact_subfolder(artifact_type)
    "#{@artifacts_folder}/#{subfolder}/clip_#{clip_id}_#{sanitized_filename}"
  end

  @doc """
  Validates that a generated S3 path is valid according to AWS S3 requirements.

  ## Examples

      iex> S3Paths.validate_s3_path("valid/path/file.mp4")
      :ok

      iex> S3Paths.validate_s3_path("invalid//double//slash.mp4")
      {:error, "Invalid S3 path: contains double slashes"}
  """
  @spec validate_s3_path(String.t()) :: :ok | {:error, String.t()}
  def validate_s3_path(path) when is_binary(path) do
    cond do
      String.length(path) > 1024 ->
        {:error, "S3 path too long (max 1024 characters)"}

      String.contains?(path, "//") ->
        {:error, "Invalid S3 path: contains double slashes"}

      String.starts_with?(path, "/") ->
        {:error, "Invalid S3 path: cannot start with slash"}

      String.ends_with?(path, "/") ->
        {:error, "Invalid S3 path: cannot end with slash"}

      not Regex.match?(~r/^[a-zA-Z0-9\!\-_\.\*'\(\)\/]+$/, path) ->
        {:error, "Invalid S3 path: contains invalid characters"}

      true ->
        :ok
    end
  end

  @doc """
  Extracts the sanitized title from an existing S3 path for consistency.

  Useful when you need to generate additional paths that should use the same
  sanitized title as an existing path.

  ## Examples

      iex> S3Paths.extract_title_from_path("masters/My_Video_123_master.mp4")
      "My_Video"
  """
  @spec extract_title_from_path(String.t()) :: String.t() | nil
  def extract_title_from_path(path) when is_binary(path) do
    case String.split(path, "/") do
      [_folder, filename] ->
        # Extract title from patterns like "Title_123_master.mp4" or "Title_timestamp.mp4"
        filename
        |> String.replace_suffix(".mp4", "")
        |> String.split("_")
        |> Enum.take_while(fn part -> not Regex.match?(~r/^\d+$/, part) end)
        |> Enum.join("_")
        |> case do
          "" -> nil
          title -> title
        end

      _ ->
        nil
    end
  end

  ## Private Implementation

  # Use the same sanitization as the main Utils module for titles
  defp sanitize_title(title) when is_binary(title) do
    title
    |> Utils.sanitize_filename()
    |> String.slice(0, @max_filename_length)
  end

  defp sanitize_title(nil), do: "unknown"
  defp sanitize_title(_), do: "unknown"

  # Sanitize general filenames (for identifiers, artifact names, etc.)
  defp sanitize_filename(filename) when is_binary(filename) do
    filename
    |> Utils.sanitize_filename()
    |> String.slice(0, @max_filename_length)
  end

  defp sanitize_filename(nil), do: "default"
  defp sanitize_filename(_), do: "default"

  # Generate timestamp for unique file naming
  defp generate_timestamp do
    DateTime.utc_now()
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
    |> String.replace("-", "")
    |> String.replace(":", "")
    |> String.replace(" ", "_")
  end

  # Get the appropriate subfolder for artifact types
  defp get_artifact_subfolder(:keyframe), do: @keyframes_subfolder
  defp get_artifact_subfolder(:thumbnail), do: @thumbnails_subfolder
  defp get_artifact_subfolder(_), do: "other"
end
