defmodule HeatersWeb.VideoUrlHelper do
  @moduledoc """
  Helper functions for generating video URLs for the tiny-file approach.

  Provides URL generation for clips using the tiny-file approach (small MP4 files
  generated on-demand) and direct URLs for exported clips.

  The tiny-file approach replaces Media Fragments with actual small files that play
  instantly with correct timeline duration.
  """

  @doc """
  Generate video URL for clips using the tiny-file approach.

  For clips without exported files (clip_filepath is nil), this triggers temp file generation in development 
  or checks for exported clips in production. For clips with exported files (clip_filepath is not nil), 
  returns direct S3 URLs.

  ## Parameters
  - `clip`: Clip struct with timing information and optional clip_filepath
  - `source_video`: Source video struct with file paths

  ## Examples

      # Clip without exported file (generated from cuts) - uses tiny-file approach
      {:ok, url, :direct_s3} = get_video_url(%{clip_filepath: nil, ...}, source_video)

      # Clip with exported file - uses direct file URL
      {:ok, url, :direct_s3} = get_video_url(%{clip_filepath: "path/to/file.mp4", ...}, source_video)
  """
  @spec get_video_url(map(), map()) ::
          {:ok, String.t(), atom()} | {:loading, nil} | {:error, String.t()}
  def get_video_url(%{clip_filepath: nil} = clip, source_video) do
    # Clip without exported file - generated from cuts/segments
    build_temp_clip_url(clip, source_video)
  end

  def get_video_url(%{clip_filepath: filepath} = _clip, _source_video)
      when not is_nil(filepath) do
    # Clip with exported file - has an actual file
    url = build_cloudfront_url(filepath)
    {:ok, url, :direct_s3}
  end

  def get_video_url(clip, _source_video) do
    # Fallback for clips without clip_filepath field or other edge cases
    {:error, "Invalid clip structure: #{inspect(Map.keys(clip))}"}
  end

  @doc """
  Check if a clip supports video streaming.

  Returns true if the clip has the necessary file available (proxy for temp clips, clip file for exported clips).
  """
  @spec streamable?(map(), map()) :: boolean()
  def streamable?(%{clip_filepath: nil}, %{proxy_filepath: proxy_path})
      when not is_nil(proxy_path),
      do: true

  def streamable?(%{clip_filepath: clip_path}, _source_video)
      when not is_nil(clip_path),
      do: true

  def streamable?(_, _), do: false

  @doc """
  Generate signed CloudFront URL for FFmpeg input.

  This generates presigned URLs optimized for FFmpeg access, with longer expiration
  times and appropriate caching headers for video processing.
  """
  @spec generate_signed_cloudfront_url(String.t()) :: {:ok, String.t()}
  def generate_signed_cloudfront_url(s3_path) do
    require Logger

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

  # Private function for temp clip URL generation
  defp build_temp_clip_url(clip, source_video) do
    if Application.get_env(:heaters, :app_env) == "development" do
      # Development: Check if temp file already exists, avoid blocking FFmpeg generation
      case check_existing_temp_file(clip) do
        {:ok, file_url} ->
          {:ok, file_url, :direct_s3}

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

  defp build_production_clip_url(%{export_key: export_key} = _clip, _source_video)
       when not is_nil(export_key) do
    # Clip already exported - return presigned URL
    bucket_name = get_bucket_name()

    case ExAws.S3.presigned_url(ExAws.Config.new(:s3), :get, bucket_name, export_key,
           expires_in: 86400 * 30
         ) do
      {:ok, url} -> {:ok, url, :direct_s3}
      {:error, reason} -> {:error, "Failed to generate presigned URL: #{inspect(reason)}"}
    end
  end

  defp build_production_clip_url(%{id: _clip_id} = _clip, _source_video) do
    # Clip not yet exported - queue export job (will be implemented in later phases)
    # For now, return loading state
    {:loading, nil}
  end

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
