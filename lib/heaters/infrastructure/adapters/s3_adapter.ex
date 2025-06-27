defmodule Heaters.Infrastructure.Adapters.S3Adapter do
  @moduledoc """
  S3 adapter providing consistent I/O interface for domain operations.

  This adapter wraps the existing Infrastructure.S3 module with standardized
  error handling and provides a clean interface for domain operations.
  All functions in this module perform I/O operations.
  """

  alias Heaters.Infrastructure.S3
  alias Heaters.Clips.Clip
  alias Heaters.Videos.Queries, as: VideoQueries

  @doc """
  Download a clip's video file to a local directory.

  ## Examples

      {:ok, "/tmp/video.mp4"} = S3Adapter.download_clip_video(clip, "/tmp")
      {:error, reason} = S3Adapter.download_clip_video(clip, "/invalid/path")
  """
  @spec download_clip_video(map(), String.t(), String.t()) :: {:ok, String.t()} | {:error, any()}
  def download_clip_video(clip, temp_dir, local_filename) do
    local_path = Path.join(temp_dir, local_filename)
    s3_key = String.trim_leading(clip.clip_filepath, "/")

    case S3.download_file(s3_key, local_path, operation_name: "ClipDownload") do
      {:ok, ^local_path} -> {:ok, local_path}
      error -> error
    end
  end

  @doc """
  Upload a sprite sheet to S3 and return metadata.

  ## Examples

      upload_data = %{s3_key: "sprites/sprite.jpg", metadata: %{file_size: 1024}}
      {:ok, ^upload_data} = S3Adapter.upload_sprite("/tmp/sprite.jpg", clip, "sprite.jpg")
  """
  @spec upload_sprite(String.t(), Clip.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def upload_sprite(local_sprite_path, %Clip{} = clip, filename)
      when is_binary(local_sprite_path) and is_binary(filename) do
    s3_prefix = build_artifact_prefix(clip, "sprite_sheets")
    s3_key = "#{s3_prefix}/#{filename}"

    case S3.upload_file(local_sprite_path, s3_key, operation_name: "SpriteUpload") do
      {:ok, _upload_result} ->
        file_size = get_file_size(local_sprite_path)

        result = %{
          s3_key: s3_key,
          metadata: %{
            file_size: file_size,
            filename: filename,
            upload_timestamp: DateTime.utc_now()
          }
        }

        {:ok, result}

      error ->
        error
    end
  end

  @doc """
  Upload keyframe images to S3.

  Returns a list of artifact data for each uploaded keyframe.
  """
  @spec upload_keyframes(list(String.t()), Clip.t(), String.t()) ::
          {:ok, list(map())} | {:error, any()}
  def upload_keyframes(local_keyframe_paths, %Clip{} = _clip, prefix)
      when is_list(local_keyframe_paths) and is_binary(prefix) do
    results =
      local_keyframe_paths
      |> Enum.with_index()
      |> Enum.map(fn {local_path, index} ->
        filename = "keyframe_#{index + 1}.jpg"
        s3_key = "#{prefix}/#{filename}"

        case S3.upload_file(local_path, s3_key, operation_name: "KeyframeUpload") do
          {:ok, _upload_result} ->
            file_size = get_file_size(local_path)

            {:ok,
             %{
               s3_key: s3_key,
               metadata: %{
                 file_size: file_size,
                 filename: filename,
                 position: index + 1,
                 upload_timestamp: DateTime.utc_now()
               }
             }}

          error ->
            error
        end
      end)

    # Check if all uploads succeeded
    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      nil ->
        # All uploads succeeded
        artifacts = Enum.map(results, fn {:ok, artifact} -> artifact end)
        {:ok, artifacts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Upload a processed video (for split/merge operations) to S3.
  """
  @spec upload_processed_video(String.t(), Clip.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def upload_processed_video(local_video_path, %Clip{} = clip, filename)
      when is_binary(local_video_path) and is_binary(filename) do
    s3_prefix = build_artifact_prefix(clip, "processed")
    s3_key = "#{s3_prefix}/#{filename}"

    case S3.upload_file(local_video_path, s3_key, operation_name: "ProcessedVideo") do
      {:ok, _upload_result} ->
        file_size = get_file_size(local_video_path)

        result = %{
          s3_key: s3_key,
          metadata: %{
            file_size: file_size,
            filename: filename,
            upload_timestamp: DateTime.utc_now()
          }
        }

        {:ok, result}

      error ->
        error
    end
  end

  @doc """
  Delete files from S3.
  Useful for cleanup operations.
  """
  @spec delete_files([String.t()]) :: {:ok, map()} | {:error, any()}
  def delete_files(s3_keys) when is_list(s3_keys) do
    S3.delete_s3_objects(s3_keys)
  end

  @doc """
  Check if a file exists in S3.
  """
  @spec file_exists?(String.t()) :: boolean()
  def file_exists?(s3_path) do
    # Simple placeholder implementation - not used in current operations
    s3_key = String.trim_leading(s3_path, "/")

    case S3.download_file(s3_key, "/tmp/check_#{System.unique_integer()}",
           operation_name: "Check"
         ) do
      {:ok, temp_file} ->
        File.rm(temp_file)
        true

      {:error, _} ->
        false
    end
  end

  @spec upload_file(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, any()}
  def upload_file(local_path, s3_key, operation_name) do
    case S3.upload_file(local_path, s3_key, operation_name: operation_name) do
      {:ok, ^s3_key} -> {:ok, s3_key}
      error -> error
    end
  end

  @spec delete_file(String.t()) :: {:ok, integer()} | {:error, any()}
  def delete_file(s3_path) do
    s3_key = String.trim_leading(s3_path, "/")

    case S3.delete_s3_objects([s3_key]) do
      {:ok, deleted_count} -> {:ok, deleted_count}
      error -> error
    end
  end

  @spec delete_multiple_files(list(String.t())) :: {:ok, integer()} | {:error, any()}
  def delete_multiple_files(s3_keys) when is_list(s3_keys) do
    case S3.delete_s3_objects(s3_keys) do
      {:ok, count} -> {:ok, count}
      error -> error
    end
  end

  # Private helper functions

  defp build_artifact_prefix(%Clip{source_video_id: source_video_id}, artifact_type) do
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

  defp get_file_size(file_path) do
    case File.stat(file_path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
