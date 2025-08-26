defmodule HeatersWeb.MediaController do
  @moduledoc """
  Controller for all media-related operations in the Heaters application.

  This controller consolidates video submission and streaming functionality, providing
  a unified interface for all media operations including:

  ## Video Submission

  - Video URL submission for processing pipeline
  - Integration with background job queue (Oban)
  - Flash message handling and redirects

  ## Virtual Clip Streaming

  - Virtual clip streaming with embedded timing metadata
  - CORS-safe proxy for CloudFront video streaming
  - HTTP Range request support for frame-accurate navigation

  ## Architecture

  The controller combines two previously separate controllers:
  - Video submission (from VideoController) 
  - Virtual clip streaming (from VirtualClipController)

  This consolidation improves maintainability while keeping related media operations
  co-located in a single module.
  """

  use HeatersWeb, :controller
  require Logger
  alias Heaters.Media.Videos

  ## Video Submission

  @doc """
  Submit a video URL for processing.

  Accepts video URLs and submits them to the processing pipeline via the Videos context.
  On success, redirects back to the referring page with a success flash message.
  On failure, redirects back with an error flash message.

  ## Parameters

  - `url` - Video URL to submit for processing

  ## Response

  Redirects to the referring page with appropriate flash message.
  """
  def create_video(conn, %{"url" => url}) do
    case Videos.submit(url) do
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

  ## Virtual Clip Streaming

  @doc """
  Stream virtual clip with timing metadata for the review interface.

  Serves JSON metadata with embedded video player configuration that handles:
  - HTTP 206 range request streaming from CloudFront proxy
  - Virtual timeline with 0-based duration display
  - Frame-accurate navigation using embedded FPS data
  - Auto-looping within the specified time window

  ## Parameters

  - `video_id` - Source video ID for logging and debugging
  - `clip_id` - Clip ID for logging and debugging  
  - `proxy_url` - CloudFront URL for the source proxy file
  - `start` - Start time in seconds
  - `end` - End time in seconds
  - `duration` - Duration in seconds (for virtual timeline)
  - `fps` - Frames per second (for frame-accurate navigation)
  - `start_frame` - Start frame number
  - `end_frame` - End frame number

  ## Response

  Returns JSON metadata with virtual clip configuration for the ClipPlayer component.
  The player automatically streams from the proxy URL using HTTP 206 requests and
  displays a virtual timeline that matches the clip duration.
  """
  def stream_virtual_clip(conn, params) do
    # Extract timing parameters
    start_time = parse_float(params["start"], 0.0)
    end_time = parse_float(params["end"], 10.0)
    duration = parse_float(params["duration"], end_time - start_time)
    fps = parse_float(params["fps"], nil)
    
    # CRITICAL: FPS must be provided from database - never assume values
    if is_nil(fps) or fps <= 0 do
      Logger.error("MediaController: Missing or invalid FPS parameter for virtual clip streaming")
      return conn
      |> put_status(:bad_request)
      |> json(%{error: "Invalid fps parameter - frame-accurate operations require database FPS"})
    end

    # Extract IDs for logging
    video_id = parse_int(params["video_id"], 0)
    clip_id = parse_int(params["clip_id"], 0)
    start_frame = parse_int(params["start_frame"], 0)
    end_frame = parse_int(params["end_frame"], 0)

    # Get proxy URL
    proxy_url = params["proxy_url"] || ""

    if proxy_url == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing proxy_url parameter"})
    else
      Logger.info("""
      MediaController: Streaming virtual clip #{clip_id} from video #{video_id}
        Timing: #{start_time}s - #{end_time}s (#{Float.round(duration, 2)}s duration)
        Frames: #{start_frame} - #{end_frame} @ #{fps}fps
        Proxy: #{String.slice(proxy_url, 0, 80)}...
      """)

      # Return JSON response with virtual clip metadata
      # This will be consumed by the ClipPlayer component
      conn
      |> put_resp_content_type("application/json")
      |> json(%{
        type: "virtual_clip",
        proxy_url: url(conn, ~p"/_virtual_clip/proxy?url=#{URI.encode_www_form(proxy_url)}"),
        clip_id: clip_id,
        start_time: start_time,
        end_time: end_time,
        duration: duration
      })
    end
  end

  @doc """
  CORS-safe proxy for CloudFront video streaming.

  Forwards HTTP Range headers to CloudFront and streams back 206 Partial Content
  responses. This eliminates CORS issues that can occur when browsers make
  range requests directly to CloudFront URLs.

  ## Parameters

  - `url` - CloudFront URL to proxy

  ## Response

  Proxies the CloudFront response including:
  - HTTP 206 Partial Content status
  - Accept-Ranges and Content-Range headers
  - Video content stream with range support
  """
  def proxy_video(conn, params) do
    case params["url"] do
      url when is_binary(url) and url != "" ->
        # Decode the URL parameter since it comes URL-encoded
        decoded_url = URI.decode(url)
        proxy_request(conn, decoded_url)

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing url parameter"})
    end
  end

  ## Private Implementation

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

  # Parse float parameter with default fallback
  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {float_val, _} -> float_val
      :error -> default
    end
  end

  defp parse_float(value, _default) when is_number(value), do: value * 1.0
  defp parse_float(_, default), do: default

  # Parse integer parameter with default fallback
  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int_val, _} -> int_val
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  # Proxy HTTP request to CloudFront with range support
  defp proxy_request(conn, url) do
    # Extract Range header if present
    range_header =
      case Plug.Conn.get_req_header(conn, "range") do
        [range] -> [{"range", range}]
        _ -> []
      end

    # Make request to CloudFront with range support
    headers =
      [
        {"user-agent", "HeatersMediaController/1.0"},
        {"accept", "*/*"}
      ] ++ range_header

    Logger.debug(
      "MediaController: Proxying request to #{String.slice(url, 0, 80)}... with headers: #{inspect(headers)}"
    )

    Logger.debug("MediaController: Full URL: #{url}")

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: body}} ->
        # Forward response with appropriate headers
        conn = put_resp_headers(conn, resp_headers, status)

        conn
        |> put_status(status)
        |> send_resp(status, body)

      {:error, reason} ->
        Logger.error("MediaController: Proxy request failed: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Proxy request failed"})
    end
  end

  # Set response headers from proxied response
  defp put_resp_headers(conn, headers, _status) do
    # Forward important headers for video streaming
    video_headers = [
      "content-type",
      "content-length",
      "content-range",
      "accept-ranges",
      "cache-control",
      "etag",
      "last-modified"
    ]

    # Extract headers as map for easier processing
    header_map =
      headers
      |> Enum.into(%{}, fn
        {key, value} when is_binary(key) and is_binary(value) ->
          {String.downcase(key), value}

        {key, values} when is_binary(key) and is_list(values) ->
          {String.downcase(key), hd(values)}

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    # Add CORS headers for cross-origin requests
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "range, if-range, if-modified-since")
      |> put_resp_header(
        "access-control-expose-headers",
        "content-range, content-length, accept-ranges"
      )

    # Forward video streaming headers
    video_headers
    |> Enum.reduce(conn, fn header_name, acc_conn ->
      case Map.get(header_map, header_name) do
        nil -> acc_conn
        value -> put_resp_header(acc_conn, header_name, value)
      end
    end)
  end
end
