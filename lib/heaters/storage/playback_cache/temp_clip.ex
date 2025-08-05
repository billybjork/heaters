defmodule Heaters.Storage.PlaybackCache.TempClip do
  @moduledoc """
  Micro-proof-of-concept for generating temporary clip files using FFmpeg stream copy.

  This generates small MP4 files (2-5MB typically) that play instantly with correct
  timeline duration, replacing the Media Fragments approach for development.

  Cleanup is handled by the scheduled CleanupWorker rather than per-file timers
  for more efficient batch processing.
  """

  require Logger

  alias Heaters.Repo
  @tmp_dir System.tmp_dir!()
  @ffmpeg_bin Application.compile_env(:heaters, :ffmpeg_bin, "/usr/bin/ffmpeg")

  @doc """
  Build a temporary clip file from a clip without exported file.

  Uses FFmpeg with `-c copy` for ultra-fast stream copying without re-encoding.
  The resulting file is tiny (2-5MB) and starts playing immediately.

  ## Parameters
  - `clip`: Clip struct with timing and source video information

  ## Returns
  - `{:ok, file_url}` - file:// URL for direct browser access
  - `{:error, reason}` - FFmpeg error or missing data
  """
  @spec build(map()) :: {:ok, String.t()} | {:error, String.t()}
  def build(%{
        id: id,
        start_time_seconds: start_seconds,
        end_time_seconds: end_seconds,
        source_video: source_video
      }) do
    # Calculate duration
    duration_seconds = end_seconds - start_seconds

    # Get input URL (proxy file for temp clips)
    {:ok, proxy_url} = get_proxy_url(source_video.proxy_filepath)

    # Generate temp file path with timestamp to ensure uniqueness (use milliseconds for better precision)
    timestamp = System.system_time(:millisecond)
    tmp_file = Path.join(@tmp_dir, "clip_#{id}_#{timestamp}.mp4")

    Logger.info(
      "TempClip: Generating clip #{id} (#{start_seconds}s-#{end_seconds}s, #{Float.round(duration_seconds, 2)}s duration) from proxy: #{proxy_url}"
    )

    generate_clip_file(tmp_file, proxy_url, start_seconds, duration_seconds, timestamp)
  end

  # Handle clip without preloaded source_video
  def build(%{id: id} = _clip) do
    case Repo.get(Heaters.Media.Clip, id) do
      {:ok, clip} ->
        case Repo.preload(clip, :source_video) do
          loaded_clip -> build(loaded_clip)
        end

      {:error, :not_found} ->
        {:error, "Clip not found"}
    end
  end

  # Generate the actual clip file
  defp generate_clip_file(tmp_file, proxy_url, start_seconds, duration_seconds, timestamp) do
    # FFmpeg command with stream copy (no re-encoding)
    # Put -ss before -i for more accurate seeking with local files
    cmd_args = [
      "-hide_banner",
      "-loglevel",
      "error",
      # Overwrite output files without asking
      "-y",
      # Seek to start time (before input for better accuracy)
      "-ss",
      "#{start_seconds}",
      # Input URL (proxy file)
      "-i",
      proxy_url,
      # Duration to copy
      "-t",
      "#{duration_seconds}",
      # Stream copy (no re-encode)
      "-c",
      "copy",
      # Optimize for web playback
      "-movflags",
      "+faststart",
      # Ensure clean timestamps
      "-avoid_negative_ts",
      "make_zero",
      tmp_file
    ]

    Logger.debug("TempClip: Running FFmpeg command: #{@ffmpeg_bin} #{Enum.join(cmd_args, " ")}")

    try do
      case System.cmd(@ffmpeg_bin, cmd_args, stderr_to_stdout: true) do
        {output, 0} ->
          # Check file exists and has reasonable size
          if File.exists?(tmp_file) do
            file_size = File.stat!(tmp_file).size
            Logger.info("TempClip: Generated file: #{tmp_file} (#{file_size} bytes)")

            if file_size < 10_000 do
              Logger.warning(
                "TempClip: Generated file is suspiciously small (#{file_size} bytes), FFmpeg output: #{output}"
              )
            end

            Logger.debug("TempClip: Generated #{tmp_file} successfully")

            # Return HTTP URL for browser access via static serving with cache busting
            filename = Path.basename(tmp_file)
            # Use seconds for URL parameter to keep it shorter
            url_timestamp = div(timestamp, 1000)
            {:ok, "/temp/#{filename}?t=#{url_timestamp}"}
          else
            Logger.error("TempClip: FFmpeg reported success but file doesn't exist: #{tmp_file}")
            {:error, "FFmpeg completed but no output file created"}
          end

        {error_output, exit_code} ->
          Logger.error("TempClip: FFmpeg failed (exit #{exit_code}): #{error_output}")
          {:error, "FFmpeg failed: #{error_output}"}
      end
    catch
      :exit, {:timeout, _} ->
        Logger.error("TempClip: FFmpeg timeout - network or processing issue")
        {:error, "FFmpeg timeout - network or processing issue"}
    end
  end

  # Get proxy URL - use actual proxy file in dev when available, fallback to test file
  defp get_proxy_url(proxy_filepath) do
    if Application.get_env(:heaters, :app_env) == "development" do
      cond do
        # If we have a real proxy_filepath, try to use it (may be CloudFront URL)
        proxy_filepath != nil ->
          {:ok, url} = HeatersWeb.VideoUrlHelper.generate_signed_cloudfront_url(proxy_filepath)
          {:ok, url}

        # No proxy_filepath available, use local test file
        true ->
          Logger.warning("TempClip: No proxy_filepath available, using local test proxy")
          get_local_test_proxy()
      end
    else
      # Production: use CloudFront URL
      {:ok, url} = HeatersWeb.VideoUrlHelper.generate_signed_cloudfront_url(proxy_filepath)
      {:ok, url}
    end
  end

  # Get the local test proxy file path
  defp get_local_test_proxy do
    priv_path = Application.app_dir(:heaters, "priv")
    local_file = Path.join([priv_path, "fixtures", "proxy_local.mp4"])
    {:ok, local_file}
  end
end
