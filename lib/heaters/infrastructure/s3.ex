defmodule Heaters.Infrastructure.S3 do
  @moduledoc """
  Context for S3 operations, including file deletion.
  Provides a unified interface for S3 operations across the application.

  This module handles S3 operations that were previously done in Python,
  particularly for cleanup operations like archiving clips.
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
      case get_s3_bucket_name() do
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

  defp get_s3_bucket_name do
    case Application.get_env(:heaters, :s3_bucket) do
      nil ->
        {:error, "S3 bucket name not configured. Please set :s3_bucket in application config."}

      bucket_name ->
        {:ok, bucket_name}
    end
  end
end
