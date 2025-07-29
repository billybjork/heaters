defmodule HeatersWeb.VideoController do
  use HeatersWeb, :controller
  require Logger
  alias Heaters.Videos.Download
  alias HeatersWeb.{FFmpegPool, StreamPorts, VideoUrlHelper}

  def create(conn, %{"url" => url}) do
    case Download.submit(url) do
      :ok ->
        conn
        |> put_flash(:info, "Submitted!")
        |> redirect(to: get_referrer(conn))

      {:error, msg} ->
        conn
        |> put_flash(:error, msg)
        |> redirect(to: get_referrer(conn))
    end
  end

  @doc """
  Stream a virtual clip using FFmpeg time-based segmentation.

  Accepts requests like: /videos/clips/:clip_id/stream/:version
  Uses FFmpeg to stream only the exact time range needed for the clip.
  """
  def stream_clip(conn, %{"clip_id" => clip_id, "version" => _version}) do
    # Check FFmpeg process pool for rate limiting
    case FFmpegPool.acquire() do
      :ok ->
        try do
          do_stream_clip(conn, clip_id)
        after
          FFmpegPool.release()
        end

      :rate_limited ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", "10")
        |> json(%{error: "Too many concurrent video streams", retry_after: 10})
    end
  end

  # Fallback for requests without version (for backward compatibility)
  def stream_clip(conn, %{"clip_id" => clip_id}) do
    stream_clip(conn, %{"clip_id" => clip_id, "version" => "1"})
  end

  # Extract only the path (and query string, if any) from the Referer header.
  defp get_referrer(conn) do
    conn
    |> get_req_header("referer")
    |> List.first()
    |> case do
      nil ->
        ~p"/"

      ref ->
        %URI{path: path, query: q} = URI.parse(ref)
        if q, do: path <> "?" <> q, else: path
    end
  end

  # Core FFmpeg streaming implementation
  defp do_stream_clip(conn, clip_id) do
    case get_clip_with_source_video(clip_id) do
      {:ok, clip} ->
        case generate_signed_cloudfront_url(clip.source_video) do
          {:ok, signed_url} ->
            stream_ffmpeg_clip(conn, clip, signed_url)

          {:error, reason} ->
            Logger.error("Failed to generate signed URL for clip #{clip_id}: #{reason}")

            conn
            |> put_status(500)
            |> json(%{error: "Failed to access video source"})
        end

      {:error, reason} ->
        conn
        |> put_status(404)
        |> json(%{error: reason})
    end
  end

  defp stream_ffmpeg_clip(conn, clip, signed_url) do
    # Build FFmpeg command for time-based segmentation
    cmd = [
      "ffmpeg",
      "-hide_banner",
      "-loglevel",
      "error",
      "-ss",
      to_string(clip.start_time_seconds),
      "-to",
      to_string(clip.end_time_seconds),
      "-i",
      signed_url,
      "-c",
      "copy",
      "-movflags",
      "+faststart",
      "-f",
      "mp4",
      "pipe:1"
    ]

    Logger.debug(
      "Streaming clip #{clip.id} (#{clip.start_time_seconds}s-#{clip.end_time_seconds}s)"
    )

    # Set up chunked response with appropriate headers
    conn =
      conn
      |> put_resp_header("content-type", "video/mp4")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("cache-control", "public, max-age=31536000")
      |> put_resp_header("x-clip-id", to_string(clip.id))
      |> send_chunked(200)

    # Stream FFmpeg output directly to HTTP response
    case StreamPorts.stream(conn, cmd) do
      {:ok, conn} ->
        Logger.debug("Successfully streamed clip #{clip.id}")
        conn

      {:error, reason, conn} ->
        Logger.error("FFmpeg streaming failed for clip #{clip.id}: #{inspect(reason)}")
        conn
    end
  end

  defp get_clip_with_source_video(clip_id) do
    case Heaters.Repo.get(Heaters.Clips.Clip, clip_id) do
      nil ->
        {:error, "Clip not found"}

      clip ->
        # Only allow streaming for virtual clips
        if clip.is_virtual do
          clip = Heaters.Repo.preload(clip, :source_video)
          {:ok, clip}
        else
          {:error, "Only virtual clips can be streamed"}
        end
    end
  end

  defp generate_signed_cloudfront_url(source_video) do
    case source_video.proxy_filepath do
      nil ->
        {:error, "No proxy file available"}

      proxy_path ->
        # Generate signed CloudFront URL for FFmpeg input
        # Use CloudFront for edge caching of source video
        {:ok, signed_url} = VideoUrlHelper.generate_signed_cloudfront_url(proxy_path)
        {:ok, signed_url}
    end
  end
end
