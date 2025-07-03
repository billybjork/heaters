defmodule Heaters.Clips.Operations.Shared.FFmpegRunner do
  @moduledoc """
  Centralized FFmpeg operations for video transformations.

  This module consolidates FFmpeg command construction and execution patterns
  used across video splitting, sprite generation, merging, and metadata extraction.
  Eliminates ~140 lines of duplicated FFmpeg handling code.

  Key functions:
  - Video clip creation with standardized encoding settings
  - Sprite sheet generation with configurable parameters
  - Video concatenation with copy codec
  - Video metadata extraction via ffprobe
  """

  require Logger
  import FFmpex
  use FFmpex.Options

  @type ffmpeg_result :: {:ok, integer()} | {:error, any()}
  @type metadata_result :: {:ok, map()} | {:error, any()}

  # Standard video encoding settings used across operations
  # Conservative settings for 4K video to avoid resource exhaustion
  @video_codec "libx264"
  @video_preset "fast"      # Changed from "medium" to "fast" for lower CPU usage
  @video_crf 25            # Changed from "23" to "25" for lower quality but faster encoding
  @video_pix_fmt "yuv420p"
  @audio_codec "aac"
  @audio_bitrate "128k"
  @jpeg_quality 3

  @doc """
  Creates a video clip with standardized encoding settings.

  Replicates the FFmpeg command used in split operations:
  ffmpeg -i input -ss start_time -to end_time
    -map 0:v:0? -map 0:a:0?
    -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p
    -c:a aac -b:a 128k
    -movflags +faststart -y output

  ## Parameters
  - `input_path`: Path to input video file
  - `output_path`: Path for output video clip
  - `start_time`: Start time in seconds (float)
  - `end_time`: End time in seconds (float)

  ## Returns
  - `{:ok, file_size}` on success with output file size in bytes
  - `{:error, reason}` on failure
  """
  @spec create_video_clip(String.t(), String.t(), float(), float()) :: ffmpeg_result()
  def create_video_clip(input_path, output_path, start_time, end_time) do
    try do
      # Convert float times to strings for FFmpex compatibility
      start_time_str = Float.to_string(start_time)
      duration = end_time - start_time
      duration_str = Float.to_string(duration)

      Logger.debug("FFmpegRunner: Creating video clip with FFmpex - start_time=#{start_time}, duration=#{duration}")

      command =
        FFmpex.new_command()
        |> add_input_file(input_path)
        |> add_output_file(output_path)
        |> add_file_option(option_ss(start_time_str))
        |> add_file_option(option_t(duration_str))
        |> add_file_option(option_map("0:v:0?"))
        |> add_file_option(option_map("0:a:0?"))
        |> add_stream_specifier(stream_type: :video)
        |> add_stream_option(option_c(@video_codec))
        |> add_file_option(option_preset(@video_preset))
        |> add_file_option(option_crf(to_string(@video_crf)))
        |> add_file_option(option_pix_fmt(@video_pix_fmt))
        |> add_stream_specifier(stream_type: :audio)
        |> add_stream_option(option_c(@audio_codec))
        |> add_stream_option(option_b(@audio_bitrate))
        |> add_file_option(option_movflags("+faststart"))
        |> add_file_option(option_threads("2"))
        |> add_global_option(option_y())

      execute_and_get_file_size(command, output_path)
    rescue
      e ->
        Logger.error("FFmpegRunner: Exception creating video clip: #{inspect(e)}")
        {:error, "Exception creating video clip: #{inspect(e)}"}
    end
  end

  @doc """
  Generates a sprite sheet from video with configurable parameters.

  Replicates the FFmpeg command used in sprite operations:
  ffmpeg -y -i input -vf "fps=X,scale=W:H:flags=neighbor,tile=CxR" -an -qscale:v 3 output.jpg

  ## Parameters
  - `input_path`: Path to input video file
  - `output_path`: Path for output sprite sheet
  - `sprite_fps`: Target FPS for sprite sampling
  - `tile_width`: Width of individual tiles in pixels
  - `tile_height`: Height of individual tiles in pixels
  - `cols`: Number of columns in sprite grid
  - `num_rows`: Number of rows in sprite grid

  ## Returns
  - `{:ok, file_size}` on success with output file size in bytes
  - `{:error, reason}` on failure
  """
  @spec create_sprite_sheet(
          String.t(),
          String.t(),
          float(),
          integer(),
          integer(),
          integer(),
          integer()
        ) :: ffmpeg_result()
  def create_sprite_sheet(
        input_path,
        output_path,
        sprite_fps,
        tile_width,
        tile_height,
        cols,
        num_rows
      ) do
    try do
      # Build video filter: fps=X,scale=W:H:flags=neighbor,tile=CxR
      vf_filter =
        "fps=#{sprite_fps},scale=#{tile_width}:#{tile_height}:flags=neighbor,tile=#{cols}x#{num_rows}"

      command =
        FFmpex.new_command()
        |> add_global_option(option_y())
        |> add_input_file(input_path)
        |> add_output_file(output_path)
        |> add_file_option(option_vf(vf_filter))
        |> add_file_option(option_an())
        |> add_file_option(option_qscale("#{@jpeg_quality}"))

      execute_and_get_file_size(command, output_path)
    rescue
      e ->
        {:error, "Exception creating sprite sheet: #{inspect(e)}"}
    end
  end

  @doc """
  Merges multiple video files using FFmpeg concat demuxer.

  Replicates the FFmpeg command used in merge operations:
  ffmpeg -f concat -i concat_list.txt -c copy -y output.mp4

  ## Parameters
  - `concat_list_path`: Path to concat list file containing input videos
  - `output_path`: Path for merged output video

  ## Returns
  - `{:ok, file_size}` on success with output file size in bytes
  - `{:error, reason}` on failure
  """
  @spec merge_videos(String.t(), String.t()) :: ffmpeg_result()
  def merge_videos(concat_list_path, output_path) do
    try do
      command =
        FFmpex.new_command()
        |> add_global_option(option_f("concat"))
        |> add_input_file(concat_list_path)
        |> add_output_file(output_path)
        |> add_file_option(option_c("copy"))
        |> add_file_option(option_y())

      execute_and_get_file_size(command, output_path)
    rescue
      e ->
        {:error, "Exception merging videos: #{inspect(e)}"}
    end
  end

  @doc """
  Extracts comprehensive video metadata using ffprobe.

  Replicates the ffprobe command used in sprite operations:
  ffprobe -v error -select_streams v:0 -show_entries stream=duration,r_frame_rate,nb_frames -count_frames -of json video_path

  ## Parameters
  - `video_path`: Path to video file to analyze

  ## Returns
  - `{:ok, metadata}` with map containing duration, fps, and total_frames
  - `{:error, reason}` on failure
  """
  @spec get_video_metadata(String.t()) :: metadata_result()
  def get_video_metadata(video_path) do
    try do
      {output, exit_code} =
        System.cmd("ffprobe", [
          "-v",
          "error",
          "-select_streams",
          "v:0",
          "-show_entries",
          "stream=duration,r_frame_rate,nb_frames",
          "-count_frames",
          "-of",
          "json",
          video_path
        ])

      if exit_code == 0 do
        case Jason.decode(output) do
          {:ok, %{"streams" => [probe_data | _]}} ->
            parse_video_metadata(probe_data)

          {:ok, %{"streams" => []}} ->
            {:error, "ffprobe found no video streams in #{video_path}"}

          {:error, reason} ->
            {:error, "Failed to parse ffprobe JSON output: #{inspect(reason)}"}
        end
      else
        Logger.error("FFmpegRunner: FFprobe command failed with exit code #{exit_code}")
        {:error, "FFprobe command failed with exit code #{exit_code}"}
      end
    rescue
      e ->
        Logger.error("FFmpegRunner: Exception getting video metadata: #{Exception.message(e)}")
        {:error, "Exception getting video metadata: #{Exception.message(e)}"}
    end
  end

  @doc """
  Extracts video frame rate using ffprobe (simpler version for split operations).

  Used when only FPS is needed rather than full metadata.

  ## Parameters
  - `video_path`: Path to video file to analyze

  ## Returns
  - `{:ok, fps}` with frame rate as float
  - `{:error, reason}` on failure, defaults to 30.0 FPS
  """
  @spec get_video_fps(String.t()) :: {:ok, float()} | {:error, any()}
  def get_video_fps(video_path) do
    try do
      {output, exit_code} =
        System.cmd("ffprobe", [
          "-v",
          "error",
          "-select_streams",
          "v:0",
          "-show_entries",
          "stream=r_frame_rate",
          "-of",
          "csv=p=0",
          video_path
        ])

      if exit_code == 0 do
        fps_string = String.trim(output)

        case String.split(fps_string, "/") do
          [num_str, den_str] ->
            with {num, ""} <- Integer.parse(num_str),
                 {den, ""} <- Integer.parse(den_str),
                 true <- den > 0 do
              fps = num / den
              Logger.info("FFmpegRunner: Detected video FPS: #{Float.round(fps, 3)}")
              {:ok, fps}
            else
              _ ->
                Logger.warning(
                  "FFmpegRunner: Could not parse FPS from '#{fps_string}', defaulting to 30.0"
                )

                {:ok, 30.0}
            end

          _ ->
            Logger.warning(
              "FFmpegRunner: Could not parse FPS from '#{fps_string}', defaulting to 30.0"
            )

            {:ok, 30.0}
        end
      else
        Logger.warning(
          "FFmpegRunner: FFprobe command failed with exit code #{exit_code}, defaulting to 30.0"
        )

        {:ok, 30.0}
      end
    rescue
      e ->
        Logger.warning("FFmpegRunner: Exception getting FPS: #{inspect(e)}, defaulting to 30.0")
        {:ok, 30.0}
    end
  end

  ## Private helper functions

  @spec execute_and_get_file_size(FFmpex.Command.t(), String.t()) :: ffmpeg_result()
  defp execute_and_get_file_size(command, output_path) do
    case FFmpex.execute(command) do
      {:ok, _output} ->
        # Verify the file was created and get its size
        case File.stat(output_path) do
          {:ok, %File.Stat{size: file_size}} ->
            {:ok, file_size}

          {:error, reason} ->
            {:error, "Created file not found: #{reason}"}
        end

      {:error, reason} ->
        {:error, "FFmpeg error: #{reason}"}
    end
  end

  @spec parse_video_metadata(map()) :: metadata_result()
  defp parse_video_metadata(probe_data) do
    Logger.debug("FFmpegRunner: ffprobe result: #{inspect(probe_data)}")

    with {:ok, duration} <- extract_duration(probe_data),
         {:ok, fps} <- extract_fps(probe_data),
         {:ok, total_frames} <- extract_total_frames(probe_data, duration, fps) do
      if duration <= 0 or fps <= 0 or total_frames <= 0 do
        {:error,
         "Invalid video metadata: duration=#{duration}s, fps=#{fps}, frames=#{total_frames}"}
      else
        metadata = %{
          duration: duration,
          fps: fps,
          total_frames: total_frames
        }

        {:ok, metadata}
      end
    else
      error -> error
    end
  end

  defp extract_duration(%{"duration" => duration_str}) when is_binary(duration_str) do
    case Float.parse(duration_str) do
      {duration, ""} -> {:ok, duration}
      _ -> {:error, "Could not parse duration: #{duration_str}"}
    end
  end

  defp extract_duration(_), do: {:error, "Could not determine video duration"}

  defp extract_fps(%{"r_frame_rate" => fps_str}) when is_binary(fps_str) do
    case String.split(fps_str, "/") do
      [num_str, den_str] ->
        with {num, ""} <- Integer.parse(num_str),
             {den, ""} <- Integer.parse(den_str),
             true <- den > 0 do
          {:ok, num / den}
        else
          _ -> {:error, "Invalid frame rate: #{fps_str}"}
        end

      _ ->
        case Float.parse(fps_str) do
          {fps, ""} -> {:ok, fps}
          _ -> {:error, "Could not parse frame rate: #{fps_str}"}
        end
    end
  end

  defp extract_fps(_), do: {:error, "Could not determine frame rate"}

  defp extract_total_frames(%{"nb_frames" => nb_frames_str}, _duration, _fps)
       when is_binary(nb_frames_str) do
    case Integer.parse(nb_frames_str) do
      {total_frames, ""} when total_frames > 0 ->
        Logger.info("FFmpegRunner: Using ffprobe nb_frames: #{total_frames}")
        {:ok, total_frames}

      _ ->
        {:error, "Invalid nb_frames: #{nb_frames_str}"}
    end
  end

  defp extract_total_frames(_, duration, fps) do
    # Calculate from duration and fps as fallback
    total_frames = ceil(duration * fps)
    Logger.info("FFmpegRunner: Calculated total frames from duration*fps: #{total_frames}")
    {:ok, total_frames}
  end
end
