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
        # Get file modification time for cache busting
        file_stat = File.stat!(temp_path)

        mtime_unix =
          file_stat.mtime |> :calendar.datetime_to_gregorian_seconds() |> Integer.to_string()

        etag =
          :crypto.hash(:md5, "#{filename}-#{mtime_unix}")
          |> Base.encode16(case: :lower)

        conn
        |> put_resp_content_type("video/mp4")
        |> put_resp_header("content-disposition", "inline")
        |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
        |> put_resp_header("pragma", "no-cache")
        |> put_resp_header("etag", etag)
        |> send_file(200, temp_path)
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
