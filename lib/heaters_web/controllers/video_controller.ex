defmodule HeatersWeb.VideoController do
  use HeatersWeb, :controller
  require Logger
  alias Heaters.Media.Videos

  def create(conn, %{"url" => url}) do
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

  def serve_temp_file(conn, %{"filename" => filename}) do
    # Only serve in development mode and only .mp4 files for security
    if Application.get_env(:heaters, :app_env, "production") == "development" and
         String.ends_with?(filename, ".mp4") do
      temp_path = Path.join(System.tmp_dir!(), filename)

      if File.exists?(temp_path) do
        serve_temp_file_with_ranges(conn, temp_path, filename)
      else
        conn
        |> put_status(404)
        |> json(%{error: "File not found"})
      end
    else
      conn
      |> put_status(404)
      |> json(%{error: "Not found"})
    end
  end

  # Serve temp file with proper HTTP range support for video seeking
  # CRITICAL: 206 Partial Content responses required for frame navigation
  defp serve_temp_file_with_ranges(conn, file_path, filename) do
    {:ok, %File.Stat{size: file_size}} = File.stat(file_path)
    
    # Get file modification time for cache busting
    file_stat = File.stat!(file_path)
    mtime_unix = file_stat.mtime |> :calendar.datetime_to_gregorian_seconds() |> Integer.to_string()
    etag = :crypto.hash(:md5, "#{filename}-#{mtime_unix}") |> Base.encode16(case: :lower)

    conn =
      conn
      |> put_resp_content_type("video/mp4")
      |> put_resp_header("content-disposition", "inline")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> put_resp_header("pragma", "no-cache")
      |> put_resp_header("etag", etag)

    case get_req_header(conn, "range") do
      ["bytes=" <> spec] ->
        case parse_range_spec(spec, file_size) do
          {:ok, {start_pos, end_pos}} ->
            length = end_pos - start_pos + 1
            
            conn
            |> put_resp_header("content-range", "bytes #{start_pos}-#{end_pos}/#{file_size}")
            |> put_resp_header("content-length", Integer.to_string(length))
            |> case do
              c when c.method == "HEAD" -> send_resp(c, 206, "")
              c -> Plug.Conn.send_file(c, 206, file_path, start_pos, length)
            end

          :error ->
            # Invalid range - return 416 Range Not Satisfiable
            conn
            |> put_resp_header("content-range", "bytes */#{file_size}")
            |> send_resp(416, "Range Not Satisfiable")
        end

      _ ->
        # No range header - serve whole file
        conn
        |> put_resp_header("content-length", Integer.to_string(file_size))
        |> case do
          c when c.method == "HEAD" -> send_resp(c, 200, "")
          c -> send_file(c, 200, file_path)
        end
    end
  end

  # Parse HTTP Range header specifications
  # Supports: "N-M", "N-", "-SUFFIX"
  defp parse_range_spec(spec, file_size) do
    # Handle only the first range (ignore multi-range)
    first_range = spec |> String.split(",", parts: 2) |> hd()

    with [start_part, end_part] <- String.split(first_range, "-", parts: 2) do
      cond do
        # Format: "N-M" (specific range)
        start_part != "" and end_part != "" ->
          with {start_pos, ""} <- Integer.parse(start_part),
               {end_pos, ""} <- Integer.parse(end_part),
               true <- start_pos >= 0 and end_pos >= start_pos and end_pos < file_size do
            {:ok, {start_pos, end_pos}}
          else
            _ -> :error
          end

        # Format: "N-" (from N to end)
        start_part != "" and end_part == "" ->
          with {start_pos, ""} <- Integer.parse(start_part),
               true <- start_pos >= 0 and start_pos < file_size do
            {:ok, {start_pos, file_size - 1}}
          else
            _ -> :error
          end

        # Format: "-SUFFIX" (last SUFFIX bytes)
        start_part == "" and end_part != "" ->
          with {suffix_bytes, ""} <- Integer.parse(end_part),
               true <- suffix_bytes > 0 do
            start_pos = max(file_size - suffix_bytes, 0)
            {:ok, {start_pos, file_size - 1}}
          else
            _ -> :error
          end

        # Invalid format
        true ->
          :error
      end
    else
      _ -> :error
    end
  end

  # FFmpeg streaming methods removed - using nginx MP4 dynamic clipping instead

  # Debug endpoints removed - FFmpeg infrastructure no longer used

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
end
