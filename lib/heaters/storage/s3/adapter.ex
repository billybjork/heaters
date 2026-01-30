defmodule Heaters.Storage.S3.Adapter do
  @moduledoc """
  Domain-specific S3 adapter providing clip, artifact, and video operations.

  This adapter provides S3 operations that involve business logic and knowledge
  of domain objects (clips, videos, artifacts). For basic S3 file operations
  without domain logic, use `Heaters.Storage.S3.Core` directly.

  ## When to Use This Module

  - **Domain-specific operations**: Working with clips, videos, artifacts, or other domain objects
  - **Business logic**: S3 path construction from domain data, metadata enrichment
  - **Complex workflows**: Master/proxy uploads, artifact management, CDN operations
  - **Domain deletions**: Cleaning up domain objects and their related S3 resources

  ## When to Use S3.Core Instead

  - **Basic file operations**: Simple upload/download/delete without domain knowledge
  - **Generic S3 operations**: Working with raw S3 keys and files
  - **Infrastructure operations**: Bucket management, batch operations

  ## Design Principles

  - All functions accept domain objects (Clip structs, etc.) rather than raw S3 keys
  - S3 paths are constructed from domain object properties (video titles, clip IDs)
  - Metadata is enriched with domain-specific information
  - Operations are named from the domain perspective

  All functions in this module perform I/O operations with domain-specific logic.
  """

  alias Heaters.Storage.S3.Core

  require Logger

  # No dialyzer suppressions needed - legacy file operations removed

  @doc """
  Deletes a clip and its associated artifacts from S3.

  This is a domain-specific operation that understands the relationship between
  clips and their artifacts, gathering all related S3 keys for batch deletion.

  ## Examples

      {:ok, 5} = S3.Adapter.delete_clip_and_artifacts(clip_with_artifacts)
      {:ok, 0} = S3.Adapter.delete_clip_and_artifacts(clip_without_files)

  ## Returns
  - `{:ok, deleted_count}` on success
  - `{:error, reason}` on failure
  """
  @spec delete_clip_and_artifacts(map()) :: {:ok, integer()} | {:error, any()}
  def delete_clip_and_artifacts(clip) do
    # Get all S3 keys to delete
    artifact_keys = Enum.map(clip.clip_artifacts || [], & &1.s3_key)

    all_keys =
      [clip.clip_filepath | artifact_keys]
      |> Enum.reject(fn key -> is_nil(key) or key == "" end)

    if Enum.empty?(all_keys) do
      Logger.info("No S3 keys to delete for clip #{clip.id}")
      {:ok, 0}
    else
      Logger.info("Deleting #{length(all_keys)} S3 objects for clip #{clip.id}")
      Core.delete_s3_objects(all_keys)
    end
  end

  @doc """
  Download JSON data from S3 and parse it.

  ## Examples

      {:ok, %{"scenes" => [...]}} = S3.Adapter.download_json("scene_detection_results/123.json")
      {:error, :not_found} = S3.Adapter.download_json("missing.json")
  """
  @spec download_json(String.t()) :: {:ok, map()} | {:error, :not_found | any()}
  def download_json(s3_key) do
    # First check if the file exists using head_object
    case Core.head_object(s3_key) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      {:ok, _metadata} ->
        # File exists, proceed with download
        temp_file =
          Path.join(System.tmp_dir!(), "s3_json_#{System.unique_integer([:positive])}.json")

        try do
          with {:ok, ^temp_file} <- Core.download_file(s3_key, temp_file),
               {:ok, json_content} <- File.read(temp_file),
               {:ok, data} <- Jason.decode(json_content) do
            {:ok, data}
          else
            {:error, %Jason.DecodeError{} = error} ->
              {:error, "JSON decode error: #{Exception.message(error)}"}

            {:error, reason} ->
              {:error, reason}
          end
        after
          # Clean up temporary file
          File.rm(temp_file)
        end
    end
  end

  @doc """
  Upload data as JSON to S3.

  ## Examples

      :ok = S3.Adapter.upload_json("scene_detection_results/123.json", %{scenes: [...]})
  """
  @spec upload_json(String.t(), map() | list()) :: :ok | {:error, any()}
  def upload_json(s3_key, data) do
    # Create a temporary file for uploading
    temp_file = Path.join(System.tmp_dir!(), "s3_json_#{System.unique_integer([:positive])}.json")

    try do
      with {:ok, json_content} <- Jason.encode(data, pretty: true),
           :ok <- File.write(temp_file, json_content),
           :ok <- Core.upload_file_simple(temp_file, s3_key) do
        :ok
      else
        {:error, %Jason.EncodeError{} = error} ->
          {:error, "JSON encode error: #{Exception.message(error)}"}

        {:error, reason} ->
          {:error, "File write error: #{inspect(reason)}"}
      end
    after
      # Clean up temporary file
      File.rm(temp_file)
    end
  end

  # Legacy upload_master and upload_proxy functions removed
  # All S3 uploads now handled by Python tasks using centralized S3Paths

  @doc """
  Generate CDN URL for streaming proxy videos.

  This generates URLs that support HTTP Range requests for efficient video streaming.

  ## Examples

      "https://cdn.domain.com/review_proxies/video_123_proxy.mp4" =
        S3.Adapter.proxy_cdn_url("review_proxies/video_123_proxy.mp4")
  """
  @spec proxy_cdn_url(String.t()) :: String.t()
  def proxy_cdn_url(s3_key) do
    case get_cdn_domain() do
      {:ok, cdn_domain} ->
        # Ensure s3_key doesn't start with /
        clean_s3_key = String.trim_leading(s3_key, "/")
        "https://#{cdn_domain}/#{clean_s3_key}"

      {:error, _} ->
        # Fallback to direct S3 URL if CDN not configured
        case Core.get_bucket_name() do
          {:ok, bucket_name} ->
            clean_s3_key = String.trim_leading(s3_key, "/")
            "https://#{bucket_name}.s3.amazonaws.com/#{clean_s3_key}"

          {:error, _} ->
            # Ultimate fallback - return key as-is
            s3_key
        end
    end
  end

  @doc """
  Get range of bytes from S3 object for efficient video streaming.

  This allows downloading only the specific byte ranges needed for video seeking.

  ## Examples

      {:ok, binary_data} = S3.Adapter.get_range("review_proxies/video.mp4", 1024, 2048)
  """
  @spec get_range(String.t(), integer(), integer()) :: {:ok, binary()} | {:error, any()}
  def get_range(s3_key, start_byte, end_byte)
      when is_integer(start_byte) and is_integer(end_byte) do
    case Core.get_bucket_name() do
      {:ok, bucket_name} ->
        clean_s3_key = String.trim_leading(s3_key, "/")
        range_header = "bytes=#{start_byte}-#{end_byte}"

        require Logger
        Logger.debug("S3: Range request #{range_header} for #{clean_s3_key}")

        case ExAws.S3.get_object(bucket_name, clean_s3_key, range: range_header)
             |> ExAws.request() do
          {:ok, %{body: body}} ->
            {:ok, body}

          {:error, reason} ->
            Logger.error("S3: Range request failed for #{clean_s3_key}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helper functions

  # get_file_size function removed - no longer needed after legacy upload function removal

  defp get_cdn_domain do
    case Application.get_env(:heaters, :proxy_cdn_domain) do
      nil ->
        # Fallback to cloudfront domain for backwards compatibility
        case Application.get_env(:heaters, :cloudfront_domain) do
          nil -> {:error, "CDN domain not configured"}
          domain -> {:ok, domain}
        end

      domain ->
        {:ok, domain}
    end
  end
end
