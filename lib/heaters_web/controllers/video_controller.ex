defmodule HeatersWeb.VideoController do
  use HeatersWeb, :controller
  require Logger
  alias Heaters.Videos.Download
  alias HeatersWeb.{FFmpegPool, StreamPorts, VideoUrlHelper, KeyframeAnalyzer}

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
  def stream_clip(conn, %{"clip_id" => clip_id, "version" => version} = params) do
    Logger.info("VideoController.stream_clip called with params: #{inspect(params)}")
    Logger.info("Parsed clip_id: #{clip_id}, version: #{version}")

    # Check FFmpeg process pool for rate limiting
    case FFmpegPool.acquire() do
      :ok ->
        do_stream_clip(conn, clip_id)

      :rate_limited ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", "10")
        |> json(%{error: "Too many concurrent video streams", retry_after: 10})
    end
  end

  # Fallback for requests without version (for backward compatibility)
  def stream_clip(conn, %{"clip_id" => clip_id}) do
    Logger.info("VideoController.stream_clip called (no version) with clip_id: #{clip_id}")
    stream_clip(conn, %{"clip_id" => clip_id, "version" => "1"})
  end

  # Debug endpoints
  def reset_ffmpeg_pool(conn, _params) do
    alias HeatersWeb.FFmpegPool

    {old_active, max_count} = FFmpegPool.status()
    FFmpegPool.reset_counter()
    {new_active, _} = FFmpegPool.status()

    Logger.info("FFmpeg pool reset: #{old_active}/#{max_count} -> #{new_active}/#{max_count}")

    json(conn, %{
      message: "FFmpeg pool counter reset",
      before: %{active: old_active, max: max_count},
      after: %{active: new_active, max: max_count}
    })
  end

  def ffmpeg_pool_status(conn, _params) do
    alias HeatersWeb.FFmpegPool

    {active, max_count} = FFmpegPool.status()

    json(conn, %{
      active_processes: active,
      max_processes: max_count,
      available: max_count - active
    })
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
    Logger.info("do_stream_clip called for clip_id: #{clip_id}")

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
    duration_seconds = clip.end_time_seconds - clip.start_time_seconds

    # Analyze for potential keyframe leakage (currently logs only)
    _encoding_mode = KeyframeAnalyzer.recommend_encoding_mode(clip, clip.source_video)

    Logger.info("Starting FFmpeg stream for clip #{clip.id} (#{duration_seconds}s duration)",
      clip_id: clip.id,
      duration: duration_seconds,
      pool_status: FFmpegPool.status()
    )

    # Build FFmpeg command for streaming MP4 - input-side seeking for fast startup
    cmd = [
      "ffmpeg",
      "-hide_banner",
      "-loglevel",
      "error",
      "-ss",
      to_string(clip.start_time_seconds),
      "-i",
      signed_url,
      "-t",
      to_string(duration_seconds),
      "-c",
      "copy",
      "-f",
      "mp4",
      "-movflags",
      "frag_keyframe+empty_moov",
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
      |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "GET")
      |> put_resp_header("access-control-allow-headers", "range")
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
