defmodule Heaters.Infrastructure.S3 do
  @moduledoc """
  Context for S3 operations, including file deletion, download, and upload.
  Provides a unified interface for S3 operations across the application.

  This module handles S3 operations that were previously done in Python,
  particularly for cleanup operations like archiving clips, and now also
  handles download/upload operations for transformation workflows.
  """

  require Logger

  # S3 limit for delete_objects operation
  @max_delete_batch_size 1000

  @doc """
  Deletes a clip and its associated artifacts from S3.
  Returns {:ok, deleted_count} or {:error, reason}.
  """
  @spec delete_clip_and_artifacts(map()) :: {:ok, integer()} | {:error, any()}
  def delete_clip_and_artifacts(clip) do
    # Get all S3 keys to delete
    artifact_keys = Enum.map(clip.clip_artifacts || [], & &1.s3_key)

    all_keys =
      [clip.clip_filepath | artifact_keys]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))

    if Enum.empty?(all_keys) do
      Logger.info("No S3 keys to delete for clip #{clip.id}")
      {:ok, 0}
    else
      Logger.info("Deleting #{length(all_keys)} S3 objects for clip #{clip.id}")
      delete_s3_objects(all_keys)
    end
  end

  @doc """
  Deletes a list of S3 objects in batches.
  Returns {:ok, deleted_count} or {:error, reason}.
  """
  @spec delete_s3_objects(list(String.t())) :: {:ok, integer()} | {:error, any()}
  def delete_s3_objects(keys) when is_list(keys) do
    if Enum.empty?(keys) do
      {:ok, 0}
    else
      case get_bucket_name() do
        {:ok, bucket_name} ->
          try do
            total_deleted =
              keys
              |> Enum.chunk_every(@max_delete_batch_size)
              |> Enum.reduce(0, fn batch, acc ->
                case delete_s3_objects_batch(bucket_name, batch) do
                  {:ok, deleted_count} ->
                    acc + deleted_count

                  {:error, reason} ->
                    Logger.error("S3 batch deletion failed: #{inspect(reason)}")
                    throw({:error, reason})
                end
              end)

            Logger.info("Successfully deleted #{total_deleted} S3 objects")
            {:ok, total_deleted}
          rescue
            error ->
              Logger.error("S3 deletion error: #{Exception.message(error)}")
              {:error, Exception.message(error)}
          catch
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          Logger.error("S3 bucket name not configured: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Download a file from S3 to a local path using streaming for memory efficiency.

  ## Parameters
  - `s3_path`: S3 path (can start with / or not)
  - `local_path`: Local file path where the file should be saved
  - `opts`: Optional keyword list with options
    - `:operation_name`: String to include in log messages (defaults to "S3")

  ## Examples

      S3.download_file("/path/to/video.mp4", "/tmp/video.mp4")
      S3.download_file("clips/video.mp4", "/tmp/video.mp4", operation_name: "Split")

  ## Returns
  - `{:ok, local_path}` on success
  - `{:error, reason}` on failure
  """
  @spec download_file(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def download_file(s3_path, local_path, opts \\ []) do
    operation_name = Keyword.get(opts, :operation_name, "S3")

    case get_bucket_name() do
      {:ok, bucket_name} ->
        s3_key = String.trim_leading(s3_path, "/")

        Logger.info(
          "#{operation_name}: Downloading s3://#{bucket_name}/#{s3_key} to #{local_path}"
        )

        try do
          # Use streaming download for better memory efficiency with large files
          file = File.open!(local_path, [:write, :binary])

          try do
            ExAws.S3.get_object(bucket_name, s3_key)
            |> ExAws.stream!()
            |> Enum.each(&IO.binwrite(file, &1))
          after
            File.close(file)
          end

          if File.exists?(local_path) do
            Logger.debug("#{operation_name}: Successfully downloaded to #{local_path}")
            {:ok, local_path}
          else
            {:error, "Downloaded file does not exist at #{local_path}"}
          end
        rescue
          error ->
            Logger.error(
              "#{operation_name}: Failed to stream download from S3: #{Exception.message(error)}"
            )

            {:error, "Failed to download from S3: #{Exception.message(error)}"}
        end

      {:error, reason} ->
        Logger.error("#{operation_name}: S3 bucket name not configured: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Upload a local file to S3 using streaming for memory efficiency.

  ## Parameters
  - `local_path`: Path to the local file to upload
  - `s3_key`: S3 key where the file should be stored (without leading /)
  - `opts`: Optional keyword list with options
    - `:operation_name`: String to include in log messages (defaults to "S3")
    - `:content_type`: MIME type for the file (auto-detected if not provided)

  ## Examples

      S3.upload_file("/tmp/video.mp4", "clips/new_video.mp4")
      S3.upload_file("/tmp/sprite.jpg", "artifacts/sprite.jpg", operation_name: "Sprite")

  ## Returns
  - `{:ok, s3_key}` on success
  - `{:error, reason}` on failure
  """
  @spec upload_file(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def upload_file(local_path, s3_key, opts \\ []) do
    operation_name = Keyword.get(opts, :operation_name, "S3")

    case get_bucket_name() do
      {:ok, bucket_name} ->
        # Ensure s3_key doesn't start with /
        clean_s3_key = String.trim_leading(s3_key, "/")

        Logger.info(
          "#{operation_name}: Uploading #{local_path} to s3://#{bucket_name}/#{clean_s3_key}"
        )

        if not File.exists?(local_path) do
          {:error, "Local file does not exist: #{local_path}"}
        else
          try do
            upload_options = build_upload_options(local_path, opts)

            case ExAws.S3.Upload.stream_file(local_path)
                 |> ExAws.S3.upload(bucket_name, clean_s3_key, upload_options)
                 |> ExAws.request() do
              {:ok, _result} ->
                Logger.debug(
                  "#{operation_name}: Successfully uploaded to s3://#{bucket_name}/#{clean_s3_key}"
                )

                {:ok, clean_s3_key}

              {:error, reason} ->
                Logger.error("#{operation_name}: Failed to upload to S3: #{inspect(reason)}")
                {:error, "Failed to upload to S3: #{inspect(reason)}"}
            end
          rescue
            error ->
              Logger.error(
                "#{operation_name}: Exception during S3 upload: #{Exception.message(error)}"
              )

              {:error, "Exception during S3 upload: #{Exception.message(error)}"}
          end
        end

      {:error, reason} ->
        Logger.error("#{operation_name}: S3 bucket name not configured: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get the configured S3 bucket name.

  ## Returns
  - `{:ok, bucket_name}` if configured
  - `{:error, reason}` if not configured
  """
  @spec get_bucket_name() :: {:ok, String.t()} | {:error, String.t()}
  def get_bucket_name do
    case Application.get_env(:heaters, :s3_bucket) do
      nil ->
        {:error, "S3 bucket name not configured. Please set :s3_bucket in application config."}

      bucket_name ->
        {:ok, bucket_name}
    end
  end

  @doc """
  Build S3 path for a clip and operation type.

  Helper function to generate consistent S3 paths across transform operations.

  ## Examples

      S3.build_clip_path(clip, "splits")
      # Returns: "source_videos/123/clips/splits"

      S3.build_clip_path(clip, "sprites", "sprite_sheet.jpg")
      # Returns: "source_videos/123/clips/456/sprites/sprite_sheet.jpg"
  """
  @spec build_clip_path(map(), String.t(), String.t() | nil) :: String.t()
  def build_clip_path(clip, operation_type, filename \\ nil) do
    base_path = "source_videos/#{clip.source_video_id}/clips"

    path =
      case operation_type do
        "splits" -> "#{base_path}/splits"
        _ -> "#{base_path}/#{clip.id}/#{operation_type}"
      end

    if filename do
      "#{path}/#{filename}"
    else
      path
    end
  end

  # Private functions

  defp delete_s3_objects_batch(bucket_name, keys) when is_list(keys) do
    Logger.info("Deleting batch of #{length(keys)} S3 objects from bucket: #{bucket_name}")

    # ExAws.S3.delete_multiple_objects expects a list of keys (strings)
    case ExAws.S3.delete_multiple_objects(bucket_name, keys) |> ExAws.request() do
      {:ok, %{body: body}} ->
        # Parse the XML response body which contains delete results
        deleted_objects =
          Map.get(body, "DeleteResult", %{})
          |> Map.get("Deleted", [])
          |> List.wrap()

        errors =
          Map.get(body, "DeleteResult", %{})
          |> Map.get("Error", [])
          |> List.wrap()

        deleted_count = length(deleted_objects)

        if length(errors) > 0 do
          Logger.warning("S3 deletion had #{length(errors)} errors")

          Enum.each(errors, fn error ->
            key = Map.get(error, "Key", "unknown")
            code = Map.get(error, "Code", "unknown")
            message = Map.get(error, "Message", "unknown")
            Logger.error("Failed to delete #{key}: #{code} - #{message}")
          end)
        end

        {:ok, deleted_count}

      {:ok, response} ->
        Logger.warning("Unexpected S3 delete response: #{inspect(response)}")
        # Assume success if no explicit errors
        {:ok, length(keys)}

      {:error, reason} ->
        Logger.error("S3 delete_multiple_objects failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_upload_options(local_path, opts) do
    content_type = Keyword.get(opts, :content_type) || guess_content_type(local_path)

    base_options = []

    if content_type do
      [content_type: content_type] ++ base_options
    else
      base_options
    end
  end

  defp guess_content_type(local_path) do
    case Path.extname(local_path) |> String.downcase() do
      ".mp4" -> "video/mp4"
      ".mov" -> "video/quicktime"
      ".avi" -> "video/x-msvideo"
      ".webm" -> "video/webm"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> nil
    end
  end
end
