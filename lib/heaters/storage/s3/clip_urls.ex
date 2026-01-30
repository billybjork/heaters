defmodule Heaters.Storage.S3.ClipUrls do
  @moduledoc """
  Unified URL generation for clip video streaming.

  Provides a single interface for all clip video streaming needs in the review interface,
  automatically determining the best approach based on clip state and available resources.

  ## Supported Formats

  - **Exported Clips**: Direct S3/CloudFront URLs for pre-rendered clip files
  - **Temp Clips**: Generated temp files using FFmpeg stream copy with HTTP Range support

  ## Usage

      # Get best available video URL for clip
      {:ok, url, player_type} = ClipUrls.get_video_url(clip, source_video)

      # Check streaming support
      true = ClipUrls.streamable?(clip, source_video)
  """

  require Logger

  @type clip_data :: %{
          id: integer(),
          clip_filepath: String.t() | nil,
          start_time_seconds: float(),
          end_time_seconds: float(),
          start_frame: integer(),
          end_frame: integer(),
          source_video_id: integer()
        }

  @type source_video_data :: %{
          id: integer(),
          proxy_filepath: String.t() | nil,
          fps: float()
        }

  @type clip_url_result :: {:ok, String.t(), atom()} | {:error, String.t()}

  @doc """
  Primary interface for getting video URLs for clips.

  Automatically selects the optimal streaming format based on clip state:
  - Exported clips: Direct S3/CloudFront URLs 
  - Non-exported clips: Temp clip generation for instant playback

  ## Parameters
  - `clip`: Clip struct with timing information and optional clip_filepath
  - `source_video`: Source video struct with file paths and FPS data

  ## Returns
  - `{:ok, url, player_type}` - Success with URL and player type
  - `{:loading, nil}` - Temp clip generation needed
  - `{:error, reason}` - No streaming options available
  """
  @spec get_video_url(clip_data(), source_video_data()) ::
          {:ok, String.t(), atom()} | {:loading, nil} | {:error, String.t()}
  def get_video_url(%{clip_filepath: nil} = clip, source_video) do
    # Clip without exported file - use temp clip generation
    build_temp_clip_url(clip, source_video)
  end

  def get_video_url(%{clip_filepath: filepath} = clip, source_video) when is_binary(filepath) do
    # Clip with exported file - use direct S3/CloudFront URL
    case get_exported_clip_url(clip, source_video) do
      {:ok, url, player_type} -> {:ok, url, player_type}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_video_url(clip, _source_video) do
    {:error, "Invalid clip structure: #{inspect(Map.keys(clip))}"}
  end

  @doc """
  Check if a clip supports any form of video streaming.

  Returns true if the clip can be streamed using either exported files
  or temp clip generation.

  ## Parameters

  - `clip`: Clip struct to check
  - `source_video`: Associated source video struct

  ## Examples

      # Clip with exported file or proxy
      true = ClipUrls.streamable?(clip, source_video)

      # Clip with no streaming options
      false = ClipUrls.streamable?(clip, source_video)
  """
  @spec streamable?(clip_data(), source_video_data()) :: boolean()
  def streamable?(clip, source_video) do
    exported_clip_streamable?(clip, source_video) or temp_clip_streamable?(clip, source_video)
  end

  ## Exported Clip URLs

  @doc """
  Generate video URL for exported clips with S3/CloudFront support.

  Returns direct S3/CloudFront URLs for clips that have been exported to files.
  For clips without exported files, returns an error indicating they need processing.

  ## Parameters
  - `clip`: Clip struct with clip_filepath
  - `source_video`: Source video struct (unused but kept for API compatibility)

  ## Examples

      # Clip with exported file - uses direct file URL
      {:ok, url, :direct_s3} = get_exported_clip_url(%{clip_filepath: "path/to/file.mp4", ...}, source_video)

      # Clip without exported file - returns error
      {:error, reason} = get_exported_clip_url(%{clip_filepath: nil, ...}, source_video)
  """
  @spec get_exported_clip_url(clip_data(), source_video_data()) :: clip_url_result()
  def get_exported_clip_url(%{clip_filepath: nil}, _source_video) do
    {:error, "Clip has no exported file available"}
  end

  def get_exported_clip_url(%{clip_filepath: filepath} = _clip, _source_video)
      when is_binary(filepath) do
    # Clip with exported file - has an actual file
    url = build_cloudfront_url(filepath)
    {:ok, url, :direct_s3}
  end

  def get_exported_clip_url(clip, _source_video) do
    # Fallback for clips without clip_filepath field or other edge cases
    {:error, "Invalid clip structure: #{inspect(Map.keys(clip))}"}
  end

  @doc """
  Check if a clip supports exported file streaming.

  Returns true if the clip has an exported file available.
  """
  @spec exported_clip_streamable?(clip_data(), source_video_data()) :: boolean()
  def exported_clip_streamable?(%{clip_filepath: nil}, _source_video), do: false

  def exported_clip_streamable?(%{clip_filepath: clip_path}, _source_video)
      when is_binary(clip_path),
      do: true

  def exported_clip_streamable?(_, _), do: false

  ## Temp Clip URLs

  # Private function for playback cache URL generation
  defp build_temp_clip_url(clip, source_video) do
    if Application.get_env(:heaters, :app_env) == "development" do
      # Development: Check if temp file already exists, avoid blocking FFmpeg generation
      case check_existing_temp_file(clip) do
        {:ok, file_url} ->
          {:ok, file_url, :ffmpeg_stream}

        :not_found ->
          # Return loading state - background generation will handle creation
          {:loading, nil}
      end
    else
      # Production: Check for exported clip or queue export
      build_production_clip_url(clip, source_video)
    end
  end

  # Check if a temp file already exists for this clip
  defp check_existing_temp_file(clip) do
    tmp_dir = System.tmp_dir!()

    # Look for existing files matching this clip's pattern
    case File.ls(tmp_dir) do
      {:ok, files} ->
        matching_files =
          files
          |> Enum.filter(&String.match?(&1, ~r/^clip_#{clip.id}_\d+\.mp4$/))
          |> Enum.map(&Path.join(tmp_dir, &1))
          |> Enum.filter(&File.regular?/1)

        case matching_files do
          [file_path | _] ->
            # Found existing file, return URL
            filename = Path.basename(file_path)
            timestamp = System.system_time(:second)
            {:ok, "/temp/#{filename}?t=#{timestamp}"}

          [] ->
            :not_found
        end

      {:error, _} ->
        :not_found
    end
  end

  defp build_production_clip_url(%{export_key: nil} = _clip, _source_video) do
    # Clip not yet exported - queue export job (will be implemented in later phases)
    # For now, return loading state
    {:loading, nil}
  end

  defp build_production_clip_url(%{export_key: export_key} = _clip, _source_video)
       when is_binary(export_key) do
    # Clip already exported - return presigned URL
    bucket_name = get_bucket_name()

    case ExAws.S3.presigned_url(ExAws.Config.new(:s3), :get, bucket_name, export_key,
           expires_in: 86_400 * 30
         ) do
      {:ok, url} -> {:ok, url, :direct_s3}
      {:error, reason} -> {:error, "Failed to generate presigned URL: #{inspect(reason)}"}
    end
  end

  defp get_bucket_name do
    Application.get_env(:heaters, :s3_bucket) || "default-bucket"
  end

  @doc """
  Check if a clip supports temp clip generation.

  Returns true if the source video has a proxy file and clip has valid timing.
  """
  @spec temp_clip_streamable?(clip_data(), source_video_data()) :: boolean()
  def temp_clip_streamable?(clip, source_video) do
    case validate_temp_clip_requirements(clip, source_video) do
      :ok -> true
      {:error, _} -> false
    end
  end

  ## CloudFront URL Utilities

  @doc """
  Generate signed CloudFront URL for FFmpeg input.

  This generates presigned URLs optimized for FFmpeg access, with longer expiration
  times and appropriate caching headers for video processing.
  """
  @spec generate_signed_cloudfront_url(String.t()) :: {:ok, String.t()}
  def generate_signed_cloudfront_url(s3_path) do
    case get_cloudfront_domain() do
      nil ->
        # Development mode - use presigned S3 URLs for FFmpeg
        Logger.debug("Generating presigned URL for FFmpeg input: #{s3_path}")
        url = generate_presigned_url(s3_path)
        {:ok, url}

      cloudfront_domain ->
        # Production mode - use CloudFront URLs
        # For now, use unsigned CloudFront URLs
        # In production, you might want to implement CloudFront signed URLs
        s3_key = extract_s3_key(s3_path)
        url = "https://#{cloudfront_domain}/#{s3_key}"
        Logger.debug("Generated CloudFront URL for FFmpeg input: #{url}")
        {:ok, url}
    end
  end

  @doc """
  Build CloudFront URL from S3 path.

  Converts S3 paths to CloudFront URLs using the configured distribution domain.
  In development without CloudFront, generates presigned S3 URLs to avoid CORS issues.
  """
  @spec build_cloudfront_url(String.t()) :: String.t()
  def build_cloudfront_url(s3_path) do
    case get_cloudfront_domain() do
      nil ->
        # Development mode - use presigned URLs to avoid CORS
        Logger.debug(
          "ClipUrls: Using presigned URL for development (no CloudFront domain configured)"
        )

        generate_presigned_url(s3_path)

      cloudfront_domain ->
        # Production mode - use CloudFront domain
        Logger.debug("ClipUrls: Using CloudFront domain: #{cloudfront_domain}")
        s3_key = extract_s3_key(s3_path)
        "https://#{cloudfront_domain}/#{s3_key}"
    end
  end

  ## Private Implementation

  # Validate that clip and source video have all requirements for temp clip generation
  @spec validate_temp_clip_requirements(clip_data(), source_video_data()) ::
          :ok | {:error, String.t()}
  defp validate_temp_clip_requirements(clip, source_video) do
    cond do
      is_nil(source_video.proxy_filepath) ->
        {:error, "Source video has no proxy file for temp clip generation"}

      is_nil(clip.start_time_seconds) or is_nil(clip.end_time_seconds) ->
        {:error, "Clip missing timing information for temp clip"}

      clip.end_time_seconds <= clip.start_time_seconds ->
        {:error, "Clip has invalid timing (end <= start)"}

      is_nil(source_video.fps) or source_video.fps <= 0 ->
        {:error, "Source video missing FPS data for frame-accurate navigation"}

      true ->
        :ok
    end
  end

  # CloudFront URL utilities (shared between exported and temp clips)

  defp extract_s3_key(s3_path) do
    case String.starts_with?(s3_path, "s3://") do
      true ->
        # Full S3 URI: s3://bucket/path/to/file.mp4 -> path/to/file.mp4
        s3_path
        |> String.replace_prefix("s3://", "")
        |> String.split("/", parts: 2)
        |> case do
          [_bucket, key] -> key
          [key] -> key
        end

      false ->
        # Already a relative path
        s3_path
    end
  end

  defp generate_presigned_url(s3_path) do
    # Generate presigned URL for development to avoid CORS issues
    s3_key = extract_s3_key(s3_path)
    bucket_name = get_bucket_name()

    Logger.debug("ClipUrls: Generating presigned URL for s3://#{bucket_name}/#{s3_key}")

    # 1 hour expiration for video streaming
    ExAws.S3.presigned_url(
      ExAws.Config.new(:s3),
      :get,
      bucket_name,
      s3_key,
      expires_in: 3600
    )
    |> case do
      {:ok, url} ->
        Logger.debug("ClipUrls: Generated presigned URL successfully")
        url

      {:error, reason} ->
        Logger.warning(
          "ClipUrls: Failed to generate presigned URL: #{inspect(reason)}, falling back to direct S3"
        )

        # Fallback to direct S3 URL if presigned URL generation fails
        region = Application.get_env(:heaters, :aws_region, "us-west-1")

        case region do
          "us-east-1" -> "https://#{bucket_name}.s3.amazonaws.com/#{s3_key}"
          _ -> "https://#{bucket_name}.s3.#{region}.amazonaws.com/#{s3_key}"
        end
    end
  end

  defp get_cloudfront_domain do
    # Get CloudFront distribution domain from config
    # In development, this will be nil unless CLOUDFRONT_DEV_DOMAIN is set
    # In production, this would be your CloudFront distribution domain
    Application.get_env(:heaters, :cloudfront_domain)
  end
end
