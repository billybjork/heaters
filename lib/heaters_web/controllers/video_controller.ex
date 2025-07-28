defmodule HeatersWeb.VideoController do
  use HeatersWeb, :controller
  require Logger
  alias Heaters.Videos.Download

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
  Stream a virtual clip with time-based byte range requests.
  
  Accepts requests like: /videos/clips/:clip_id/stream
  Converts time ranges to byte ranges, then proxies to CloudFront.
  """
  def stream_clip(conn, %{"clip_id" => clip_id}) do
    case get_clip_info(clip_id) do
      {:ok, clip_info} ->
        handle_range_request(conn, clip_info)
      
      {:error, reason} ->
        conn
        |> put_status(404)
        |> json(%{error: reason})
    end
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

  defp handle_range_request(conn, clip_info) do
    %{
      cloudfront_url: cloudfront_url,
      start_time: start_time,
      end_time: end_time
    } = clip_info

    case get_req_header(conn, "range") do
      [] ->
        # No range header - return full clip range  
        get_clip_byte_range_and_proxy(conn, cloudfront_url, start_time, end_time, nil)
        
      [<<"bytes=", range_spec::binary>>] ->
        # Parse range header and combine with time constraints
        case parse_range_spec(range_spec) do
          {:ok, {req_start, req_end}} ->
            get_clip_byte_range_and_proxy(conn, cloudfront_url, start_time, end_time, {req_start, req_end})
          
          :error ->
            conn
            |> put_status(416)
            |> put_resp_header("content-range", "bytes */0")
            |> send_resp(416, "Requested Range Not Satisfiable")
        end
    end
  end

  defp get_clip_byte_range_and_proxy(conn, cloudfront_url, start_time, end_time, requested_bytes) do
    # For now, use simple constant bitrate approximation
    # TODO: Replace with proper FFprobe integration for keyframe-accurate seeking
    case estimate_byte_range(cloudfront_url, start_time, end_time) do
      {:ok, {clip_byte_start, clip_byte_end, total_size}} ->
        # Calculate final byte range considering both time constraints and browser request
        {final_start, final_end} = calculate_final_range(
          clip_byte_start, 
          clip_byte_end, 
          requested_bytes,
          total_size
        )
        
        # Proxy request to CloudFront with calculated byte range
        proxy_cloudfront_request(conn, cloudfront_url, final_start, final_end, total_size)
        
      {:error, reason} ->
        Logger.error("Failed to get byte range for clip: #{reason}")
        conn
        |> put_status(500)
        |> json(%{error: "Failed to process video clip"})
    end
  end

  defp estimate_byte_range(video_url, start_time, end_time) do
    # Simple constant bitrate estimation
    # In production, use FFprobe to get precise keyframe positions
    
    try do
      case HTTPoison.head(video_url) do
        {:ok, %{headers: headers}} ->
          total_size = 
            headers
            |> Enum.find_value(fn {key, value} -> 
              if String.downcase(key) == "content-length", do: String.to_integer(value)
            end)
          
          if total_size do
            # Estimate based on common video lengths (adjust based on your videos)
            estimated_duration = 300.0  # 5 minutes typical
            
            bytes_per_second = total_size / estimated_duration
            clip_start_byte = round(start_time * bytes_per_second)
            clip_end_byte = round(end_time * bytes_per_second)
            
            # Ensure we don't exceed file bounds
            clip_start_byte = max(0, min(clip_start_byte, total_size - 1))
            clip_end_byte = max(clip_start_byte, min(clip_end_byte, total_size - 1))
            
            {:ok, {clip_start_byte, clip_end_byte, total_size}}
          else
            {:error, "Could not determine file size"}
          end
          
        {:error, reason} ->
          {:error, "HTTP request failed: #{inspect(reason)}"}
      end
    rescue
      error ->
        {:error, "Exception: #{inspect(error)}"}
    end
  end

  defp calculate_final_range(clip_start, clip_end, requested_bytes, total_size) do
    case requested_bytes do
      nil ->
        # No specific byte range requested, return full clip range
        {clip_start, clip_end}
        
      {req_start, req_end} ->
        # Combine clip constraints with requested byte range
        final_start = max(clip_start, req_start)
        final_end = case req_end do
          nil -> clip_end
          end_byte -> min(clip_end, end_byte)
        end
        
        # Ensure bounds
        final_start = max(0, min(final_start, total_size - 1))
        final_end = max(final_start, min(final_end, total_size - 1))
        
        {final_start, final_end}
    end
  end

  defp proxy_cloudfront_request(conn, cloudfront_url, start_byte, end_byte, total_size) do
    range_header = "bytes=#{start_byte}-#{end_byte}"
    
    case HTTPoison.get(cloudfront_url, [{"Range", range_header}]) do
      {:ok, %{status_code: 206, body: body}} ->
        # Forward CloudFront response with proper headers
        content_length = end_byte - start_byte + 1
        
        conn
        |> put_status(206)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-range", "bytes #{start_byte}-#{end_byte}/#{total_size}")
        |> put_resp_header("content-length", to_string(content_length))
        |> put_resp_header("content-type", "video/mp4")
        |> put_resp_header("cache-control", "public, max-age=31536000")
        |> send_resp(206, body)
        
      {:ok, %{status_code: status_code}} ->
        Logger.error("CloudFront returned status #{status_code}")
        send_resp(conn, 502, "Bad Gateway")
        
      {:error, reason} ->
        Logger.error("Failed to proxy CloudFront request: #{inspect(reason)}")
        send_resp(conn, 502, "Bad Gateway")
    end
  end

  defp parse_range_spec(range_spec) do
    case String.split(range_spec, "-", parts: 2) do
      [start_str, end_str] ->
        try do
          start_byte = if start_str == "", do: 0, else: String.to_integer(start_str)
          end_byte = if end_str == "", do: nil, else: String.to_integer(end_str)
          {:ok, {start_byte, end_byte}}
        rescue
          _ -> :error
        end
      _ ->
        :error
    end
  end

  defp get_clip_info(clip_id) do
    # Load clip from database with source video
    case Heaters.Repo.get(Heaters.Clips.Clip, clip_id) do
      nil ->
        {:error, "Clip not found"}
        
      clip ->
        clip = Heaters.Repo.preload(clip, :source_video)
        
        case HeatersWeb.VideoUrlHelper.get_video_url(clip, clip.source_video) do
          {:ok, cloudfront_url, _player_type} ->
            {:ok, %{
              cloudfront_url: cloudfront_url,
              start_time: clip.start_time_seconds,
              end_time: clip.end_time_seconds
            }}
            
          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
