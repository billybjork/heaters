defmodule Heaters.Storage.S3.ClipUrls do
  @moduledoc """
  Unified URL generation for all clip video streaming formats.

  This module consolidates URL generation for both exported clips and virtual clips,
  providing a single interface for all clip video streaming needs in the review interface.

  ## Supported Formats

  - **Exported Clips**: Direct URLs to pre-rendered clip files stored on S3/CloudFront
  - **Virtual Clips**: Streaming URLs that use HTTP Range requests for instant playback

  ## Architecture

  The module automatically determines the best streaming approach:
  1. If clip has exported file → use direct S3/CloudFront URL
  2. If no exported file but proxy available → use virtual clip streaming
  3. Otherwise → return error indicating clip needs processing

  ## Usage

      # Auto-detect best format for clip
      {:ok, url, :direct_s3} = ClipUrls.get_clip_url(clip, source_video)
      {:ok, url, :virtual_clip} = ClipUrls.get_clip_url(clip, source_video)

      # Check streaming support
      true = ClipUrls.streamable?(clip, source_video)

      # Direct format-specific calls
      {:ok, url, :direct_s3} = ClipUrls.get_exported_clip_url(clip, source_video)
      {:ok, url, :virtual_clip} = ClipUrls.get_virtual_clip_url(clip, source_video)
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
  Get best available video URL for a clip.

  Automatically selects the optimal streaming format:
  - Exported clips: Direct S3/CloudFront URLs for pre-rendered files
  - Virtual clips: HTTP Range streaming for instant playback

  ## Parameters

  - `clip`: Clip struct with clip_filepath and timing information
  - `source_video`: Source video struct with proxy file path and FPS data

  ## Returns

  - `{:ok, url, :direct_s3}` - Direct URL to exported clip file
  - `{:ok, url, :virtual_clip}` - Virtual clip streaming URL
  - `{:error, reason}` - No streaming format available

  ## Examples

      # Clip with exported file
      {:ok, url, :direct_s3} = ClipUrls.get_clip_url(clip, source_video)

      # Clip without exported file but with proxy
      {:ok, url, :virtual_clip} = ClipUrls.get_clip_url(clip, source_video)
  """
  @spec get_clip_url(clip_data(), source_video_data()) :: clip_url_result()
  def get_clip_url(clip, source_video) do
    case get_exported_clip_url(clip, source_video) do
      {:ok, url, :direct_s3} ->
        # Exported clip available - use direct URL
        {:ok, url, :direct_s3}

      {:error, _} ->
        # No exported clip - try virtual clip streaming
        get_virtual_clip_url(clip, source_video)
    end
  end

  @doc """
  Check if a clip supports any form of video streaming.

  Returns true if the clip can be streamed using either exported files
  or virtual clip streaming.

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
    exported_clip_streamable?(clip, source_video) or virtual_clip_streamable?(clip, source_video)
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
  def get_exported_clip_url(%{clip_filepath: filepath} = _clip, _source_video)
      when not is_nil(filepath) do
    # Clip with exported file - has an actual file
    url = build_cloudfront_url(filepath)
    {:ok, url, :direct_s3}
  end

  def get_exported_clip_url(%{clip_filepath: nil}, _source_video) do
    {:error, "Clip has no exported file available"}
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
  def exported_clip_streamable?(%{clip_filepath: clip_path}, _source_video)
      when not is_nil(clip_path),
      do: true

  def exported_clip_streamable?(_, _), do: false

  ## Virtual Clip URLs

  @doc """
  Generate virtual clip URL for efficient clip playback.

  Creates a URL that streams video segments directly from CloudFront proxy files
  using HTTP Range requests and client-side time clamping. This eliminates the need
  for temp file generation while maintaining frame-accurate timing.

  ## Parameters

  - `clip`: Clip struct with timing and frame information
  - `source_video`: Source video struct with proxy file path and FPS data

  ## Returns

  - `{:ok, url, :virtual_clip}` - Success with virtual clip URL
  - `{:error, reason}` - Failure with error description

  ## Virtual URL Format

  Virtual clip URLs encode timing information and proxy file references:
  `/_virtual_clip/stream?video_id=123&start=10.5&end=25.7&fps=25.0`

  The client-side player uses this metadata to:
  - Stream from the source proxy file using HTTP 206 requests
  - Display a virtual timeline (0-based duration)  
  - Maintain frame-accurate navigation for split/merge operations
  """
  @spec get_virtual_clip_url(clip_data(), source_video_data()) :: clip_url_result()
  def get_virtual_clip_url(clip, source_video) do
    with :ok <- validate_virtual_clip_requirements(clip, source_video),
         {:ok, proxy_url} <- get_proxy_url(source_video) do
      virtual_url = build_virtual_clip_url(clip, source_video, proxy_url)
      {:ok, virtual_url, :virtual_clip}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a clip supports virtual clip streaming.

  Returns true if the clip has all requirements for virtual clip playback:
  - Source video has proxy file available
  - Clip has valid timing information
  - FPS data available for frame-accurate operations

  ## Parameters

  - `clip`: Clip struct to check
  - `source_video`: Associated source video struct

  ## Examples

      # Clip with valid proxy file and timing
      true = virtual_clip_streamable?(clip, %{proxy_filepath: "path/to/proxy.mp4", fps: 25.0})

      # Clip missing proxy file
      false = virtual_clip_streamable?(clip, %{proxy_filepath: nil, fps: 25.0})
  """
  @spec virtual_clip_streamable?(clip_data(), source_video_data()) :: boolean()
  def virtual_clip_streamable?(clip, source_video) do
    case validate_virtual_clip_requirements(clip, source_video) do
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

  # Validate that clip and source video have all requirements for virtual clip playback
  @spec validate_virtual_clip_requirements(clip_data(), source_video_data()) ::
          :ok | {:error, String.t()}
  defp validate_virtual_clip_requirements(clip, source_video) do
    cond do
      is_nil(source_video.proxy_filepath) ->
        {:error, "Source video has no proxy file for virtual clip streaming"}

      is_nil(clip.start_time_seconds) or is_nil(clip.end_time_seconds) ->
        {:error, "Clip missing timing information for virtual clip"}

      clip.end_time_seconds <= clip.start_time_seconds ->
        {:error, "Clip has invalid timing (end <= start)"}

      is_nil(source_video.fps) or source_video.fps <= 0 ->
        {:error, "Source video missing FPS data for frame-accurate navigation"}

      true ->
        :ok
    end
  end

  # Get the proxy URL for the source video
  @spec get_proxy_url(source_video_data()) :: {:ok, String.t()}
  defp get_proxy_url(%{proxy_filepath: proxy_filepath} = _source_video) do
    generate_signed_cloudfront_url(proxy_filepath)
  end

  # Build the virtual clip URL with embedded timing and metadata
  @spec build_virtual_clip_url(clip_data(), source_video_data(), String.t()) :: String.t()
  defp build_virtual_clip_url(clip, source_video, proxy_url) do
    # Calculate duration for virtual timeline
    duration_seconds = clip.end_time_seconds - clip.start_time_seconds

    # Build query parameters with timing metadata
    params = %{
      "video_id" => source_video.id,
      "clip_id" => clip.id,
      "proxy_url" => proxy_url,
      "start" => Float.to_string(clip.start_time_seconds),
      "end" => Float.to_string(clip.end_time_seconds),
      "duration" => Float.to_string(duration_seconds),
      "fps" => Float.to_string(source_video.fps),
      "start_frame" => Integer.to_string(clip.start_frame),
      "end_frame" => Integer.to_string(clip.end_frame),
      # Add timestamp for cache busting
      "t" => Integer.to_string(System.system_time(:second))
    }

    query_string = URI.encode_query(params)

    Logger.debug("""
    ClipUrls: Generated virtual clip URL
      Clip ID: #{clip.id}
      Source Video ID: #{source_video.id}  
      Timing: #{clip.start_time_seconds}s - #{clip.end_time_seconds}s (#{Float.round(duration_seconds, 2)}s)
      Frames: #{clip.start_frame} - #{clip.end_frame}
      FPS: #{source_video.fps}
    """)

    "/_virtual_clip/stream?#{query_string}"
  end

  # CloudFront URL utilities (shared between exported and virtual clips)

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

  defp get_bucket_name do
    Application.get_env(:heaters, :s3_bucket) || "default-bucket"
  end
end
