defmodule Heaters.Infrastructure.Adapters.S3Adapter do
  @moduledoc """
  Domain-specific S3 adapter providing clip and artifact operations.

  This adapter provides domain-specific S3 operations that add business logic
  beyond basic file operations. For basic S3 operations (upload_file, download_file,
  delete_file, head_object), use Heaters.Infrastructure.S3 directly.

  All functions in this module perform I/O operations with domain-specific logic.
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
  @spec upload_sprite(String.t(), Clip.t(), String.t(), map()) :: {:ok, map()} | {:error, any()}
  def upload_sprite(local_sprite_path, %Clip{} = clip, filename, sprite_metadata \\ %{})
      when is_binary(local_sprite_path) and is_binary(filename) and is_map(sprite_metadata) do
    s3_prefix = build_artifact_prefix(clip, "sprite_sheets")
    s3_key = "#{s3_prefix}/#{filename}"

    case S3.upload_file(local_sprite_path, s3_key, operation_name: "SpriteUpload") do
      {:ok, _upload_result} ->
        file_size = get_file_size(local_sprite_path)

        # Merge sprite generation metadata with upload metadata
        combined_metadata =
          sprite_metadata
          |> Map.put("file_size", file_size)
          |> Map.put("filename", filename)
          |> Map.put("upload_timestamp", DateTime.utc_now())

        result = %{
          s3_key: s3_key,
          metadata: combined_metadata
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
  Download JSON data from S3 and parse it.

  ## Examples

      {:ok, %{"scenes" => [...]}} = S3Adapter.download_json("scene_detection_results/123.json")
      {:error, :not_found} = S3Adapter.download_json("missing.json")
  """
  @spec download_json(String.t()) :: {:ok, map()} | {:error, :not_found | any()}
  def download_json(s3_key) do
    # First check if the file exists using head_object
    case S3.head_object(s3_key) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      {:ok, _metadata} ->
        # File exists, proceed with download
        temp_file =
          Path.join(System.tmp_dir!(), "s3_json_#{System.unique_integer([:positive])}.json")

        try do
          case S3.download_file(s3_key, temp_file) do
            {:ok, ^temp_file} ->
              case File.read(temp_file) do
                {:ok, json_content} ->
                  case Jason.decode(json_content) do
                    {:ok, data} ->
                      {:ok, data}

                    {:error, %Jason.DecodeError{} = error} ->
                      {:error, "JSON decode error: #{Exception.message(error)}"}
                  end

                {:error, reason} ->
                  {:error, "File read error: #{inspect(reason)}"}
              end

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

      :ok = S3Adapter.upload_json("scene_detection_results/123.json", %{scenes: [...]})
  """
  @spec upload_json(String.t(), map() | list()) :: :ok | {:error, any()}
  def upload_json(s3_key, data) do
    # Create a temporary file for uploading
    temp_file = Path.join(System.tmp_dir!(), "s3_json_#{System.unique_integer([:positive])}.json")

    try do
      case Jason.encode(data, pretty: true) do
        {:ok, json_content} ->
          case File.write(temp_file, json_content) do
            :ok ->
              case S3.upload_file_simple(temp_file, s3_key) do
                :ok -> :ok
                error -> error
              end

            {:error, reason} ->
              {:error, "File write error: #{inspect(reason)}"}
          end

        {:error, %Jason.EncodeError{} = error} ->
          {:error, "JSON encode error: #{Exception.message(error)}"}
      end
    after
      # Clean up temporary file
      File.rm(temp_file)
    end
  end

  @doc """
  Upload master video to cold storage with appropriate storage class.

  ## Examples

      {:ok, result} = S3Adapter.upload_master("/tmp/master.mkv", source_video, "video_123_master.mkv")
  """
  @spec upload_master(String.t(), map(), String.t()) :: {:ok, map()} | {:error, any()}
  def upload_master(local_video_path, source_video, filename)
      when is_binary(local_video_path) and is_binary(filename) do
    s3_key = "masters/#{filename}"

    # Use GLACIER storage for cost-effective cold storage of archival masters
    case S3.upload_file(local_video_path, s3_key,
           operation_name: "Master",
           storage_class: "GLACIER"
         ) do
      {:ok, _} ->
        file_size = get_file_size(local_video_path)

        result = %{
          s3_key: s3_key,
          metadata: %{
            file_size: file_size,
            filename: filename,
            storage_class: "GLACIER",
            video_title: source_video.title,
            upload_timestamp: DateTime.utc_now()
          }
        }

        {:ok, result}

      error ->
        error
    end
  end

  @doc """
  Upload proxy video to hot storage for fast streaming access and export.

  ## Examples

      {:ok, result} = S3Adapter.upload_proxy("/tmp/proxy.mp4", source_video, "video_123_proxy.mp4")
  """
  @spec upload_proxy(String.t(), map(), String.t()) :: {:ok, map()} | {:error, any()}
  def upload_proxy(local_video_path, source_video, filename)
      when is_binary(local_video_path) and is_binary(filename) do
    s3_key = "proxies/#{filename}"

    # Use STANDARD storage for hot access during review and export
    case S3.upload_file(local_video_path, s3_key,
           operation_name: "Proxy",
           storage_class: "STANDARD"
         ) do
      {:ok, _} ->
        file_size = get_file_size(local_video_path)

        result = %{
          s3_key: s3_key,
          metadata: %{
            file_size: file_size,
            filename: filename,
            storage_class: "STANDARD",
            video_title: source_video.title,
            upload_timestamp: DateTime.utc_now()
          }
        }

        {:ok, result}

      error ->
        error
    end
  end

  @doc """
  Generate CDN URL for streaming proxy videos with WebCodecs support.

  This generates URLs that support HTTP Range requests, which are critical
  for WebCodecs to efficiently seek and decode video frames.

  ## Examples

      "https://cdn.domain.com/review_proxies/video_123_proxy.mp4" =
        S3Adapter.proxy_cdn_url("review_proxies/video_123_proxy.mp4")
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
        case S3.get_bucket_name() do
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
  Get range of bytes from S3 object to support WebCodecs seeking.

  This is critical for WebCodecs performance - allows downloading only
  the keyframes needed for a specific time range.

  ## Examples

      {:ok, binary_data} = S3Adapter.get_range("review_proxies/video.mp4", 1024, 2048)
  """
  @spec get_range(String.t(), integer(), integer()) :: {:ok, binary()} | {:error, any()}
  def get_range(s3_key, start_byte, end_byte)
      when is_integer(start_byte) and is_integer(end_byte) do
    case S3.get_bucket_name() do
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

  defp get_cdn_domain() do
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
