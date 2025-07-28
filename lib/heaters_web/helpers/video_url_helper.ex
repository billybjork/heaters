defmodule HeatersWeb.VideoUrlHelper do
  @moduledoc """
  Helper functions for generating CloudFront video streaming URLs.

  Provides URL generation for virtual clips using CloudFront's native byte-range 
  capabilities and direct URLs for physical clips.

  CloudFront automatically handles HTTP Range requests, so we generate simple URLs
  and let the native HTML5 video element handle seeking via byte-range requests.
  """

  @doc """
  Generate CloudFront streaming URL for virtual or physical clips.

  For virtual clips, returns the proxy URL which supports byte-range requests.
  For physical clips, returns the direct clip file URL.

  ## Parameters
  - `clip`: Clip struct with timing information
  - `source_video`: Source video struct with file paths

  ## Examples

      # Virtual clip - uses proxy file for byte-range streaming
      {:ok, url, :cloudfront_range} = get_video_url(virtual_clip, source_video)

      # Physical clip - uses direct file URL
      {:ok, url, :direct_s3} = get_video_url(physical_clip, source_video)
  """
  @spec get_video_url(map(), map()) :: {:ok, String.t(), atom()} | {:error, String.t()}
  def get_video_url(%{is_virtual: true} = _clip, source_video) do
    case source_video.proxy_filepath do
      nil ->
        {:error, "No proxy file available for virtual clip"}

      proxy_path ->
        url = build_cloudfront_url(proxy_path)
        {:ok, url, :cloudfront_range}
    end
  end

  def get_video_url(%{is_virtual: false} = clip, _source_video) do
    case clip.clip_filepath do
      nil ->
        {:error, "No clip file available for physical clip"}

      filepath ->
        url = build_cloudfront_url(filepath)
        {:ok, url, :direct_s3}
    end
  end

  @doc """
  Check if a clip supports CloudFront streaming.

  Returns true if the clip has the necessary file available (proxy for virtual, clip file for physical).
  """
  @spec streamable?(map(), map()) :: boolean()
  def streamable?(%{is_virtual: true}, %{proxy_filepath: proxy_path}) when not is_nil(proxy_path),
    do: true

  def streamable?(%{is_virtual: false, clip_filepath: clip_path}, _source_video)
      when not is_nil(clip_path),
      do: true

  def streamable?(_, _), do: false

  @doc """
  Generate signed CloudFront URL for FFmpeg input.

  This generates presigned URLs optimized for FFmpeg access, with longer expiration
  times and appropriate caching headers for video processing.
  """
  @spec generate_signed_cloudfront_url(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def generate_signed_cloudfront_url(s3_path) do
    require Logger

    case get_cloudfront_domain() do
      nil ->
        # Development mode - use presigned S3 URLs for FFmpeg
        Logger.debug("Generating presigned URL for FFmpeg input: #{s3_path}")
        {:ok, generate_presigned_url(s3_path)}

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
    require Logger

    case get_cloudfront_domain() do
      nil ->
        # Development mode - use presigned URLs to avoid CORS
        Logger.debug(
          "VideoUrlHelper: Using presigned URL for development (no CloudFront domain configured)"
        )

        generate_presigned_url(s3_path)

      cloudfront_domain ->
        # Production mode - use CloudFront domain
        Logger.debug("VideoUrlHelper: Using CloudFront domain: #{cloudfront_domain}")
        s3_key = extract_s3_key(s3_path)
        "https://#{cloudfront_domain}/#{s3_key}"
    end
  end

  # Private functions

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
    require Logger

    # Generate presigned URL for development to avoid CORS issues
    s3_key = extract_s3_key(s3_path)
    bucket_name = get_bucket_name()

    Logger.debug("VideoUrlHelper: Generating presigned URL for s3://#{bucket_name}/#{s3_key}")

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
        Logger.debug("VideoUrlHelper: Generated presigned URL successfully")
        url

      {:error, reason} ->
        Logger.warning(
          "VideoUrlHelper: Failed to generate presigned URL: #{inspect(reason)}, falling back to direct S3"
        )

        # Fallback to direct S3 URL if presigned URL generation fails
        region = Application.get_env(:heaters, :aws_region, "us-east-1")

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
    Application.get_env(:heaters, :s3_dev_bucket_name) ||
      Application.get_env(:heaters, :s3)[:dev_bucket_name] ||
      System.get_env("S3_DEV_BUCKET_NAME") ||
      "default-bucket"
  end
end
