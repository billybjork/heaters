defmodule Heaters.Processing.Render.FFmpegRunner do
  @moduledoc """
  Centralized FFmpeg operations for video processing.

  This module consolidates FFmpeg command construction and execution patterns
  used for video clip creation, video concatenation, and metadata extraction.

  Key functions:
  - Video clip creation with standardized encoding settings
  - Keyframe extraction at specific timestamps or percentages
  - Video metadata extraction via ffprobe
  """

  require Logger
  import FFmpex
  use FFmpex.Options

  alias Heaters.Processing.Render.FFmpegConfig

  @type ffmpeg_result :: {:ok, integer()} | {:error, any()}
  @type metadata_result :: {:ok, map()} | {:error, any()}

  @doc """
  Creates a video clip with encoding settings from FFmpegConfig.

  Uses the keyframe_extraction profile by default for internal operations,
  but can be customized with the :profile option.

  ## Parameters
  - `input_path`: Path to input video file
  - `output_path`: Path for output video clip
  - `start_time`: Start time in seconds (float)
  - `end_time`: End time in seconds (float)
  - `opts`: Optional parameters
    - `:profile` - FFmpeg profile to use (default: :keyframe_extraction)

  ## Returns
  - `{:ok, file_size}` on success with output file size in bytes
  - `{:error, reason}` on failure
  """
  @spec create_video_clip(String.t(), String.t(), float(), float(), keyword()) :: ffmpeg_result()
  def create_video_clip(input_path, output_path, start_time, end_time, opts \\ []) do
    try do
      # Get encoding profile configuration
      profile = Keyword.get(opts, :profile, :keyframe_extraction)
      config = FFmpegConfig.get_profile_config(profile)

      # Convert float times to strings for FFmpex compatibility
      start_time_str = Float.to_string(start_time)
      duration = end_time - start_time
      duration_str = Float.to_string(duration)

      Logger.debug(
        "FFmpegRunner: Creating video clip with profile #{profile} - start_time=#{start_time}, duration=#{duration}"
      )

      # Additional validation for very short clips
      if duration < 1.0 do
        Logger.debug(
          "FFmpegRunner: Creating short clip (#{duration}s) - using profile: #{profile}"
        )
      end

      command =
        FFmpex.new_command()
        |> add_input_file(input_path)
        |> add_file_option(option_ss(start_time_str))
        |> add_output_file(output_path)
        |> add_file_option(option_t(duration_str))
        |> add_file_option(option_map("0:v:0?"))
        |> add_file_option(option_map("0:a:0?"))
        |> add_profile_encoding_options(config)
        |> add_global_option(option_y())

      execute_and_get_file_size(command, output_path)
    rescue
      e ->
        Logger.error("FFmpegRunner: Exception creating video clip: #{inspect(e)}")
        {:error, "Exception creating video clip: #{inspect(e)}"}
    end
  end

  @doc """
  Extracts comprehensive video metadata using ffprobe.

  Replicates the ffprobe command used for video analysis:
  ffprobe -v error -select_streams v:0 -show_entries stream=duration,r_frame_rate,nb_frames,width,height -count_frames -of json video_path

  ## Parameters
  - `video_path`: Path to video file to analyze

  ## Returns
  - `{:ok, metadata}` with map containing duration, fps, total_frames, width, and height
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
          "stream=duration,r_frame_rate,nb_frames,width,height",
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
  Extracts video frame rate using ffprobe.

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

  @spec add_profile_encoding_options(FFmpex.Command.t(), map()) :: FFmpex.Command.t()
  defp add_profile_encoding_options(command, config) do
    command
    |> add_video_encoding_options(config.video)
    |> add_audio_encoding_options(config[:audio])
    |> add_web_optimization_options(config[:web_optimization])
    |> add_threading_options(config[:threading])
  end

  defp add_video_encoding_options(command, video_config) do
    command
    |> add_stream_specifier(stream_type: :video)
    |> add_stream_option(option_c(video_config.codec))
    |> add_optional_file_option(&option_preset/1, video_config[:preset])
    |> add_optional_file_option(&option_crf/1, video_config[:crf])
    |> add_optional_file_option(&option_pix_fmt/1, video_config[:pix_fmt])
    |> add_optional_file_option(&option_g/1, video_config[:gop_size])
  end

  defp add_audio_encoding_options(command, nil), do: command

  defp add_audio_encoding_options(command, audio_config) do
    command
    |> add_stream_specifier(stream_type: :audio)
    |> add_stream_option(option_c(audio_config.codec))
    |> add_optional_stream_option(&option_b/1, audio_config[:bitrate])
  end

  defp add_web_optimization_options(command, nil), do: command

  defp add_web_optimization_options(command, web_opts) do
    command
    |> add_optional_file_option(&option_movflags/1, web_opts[:movflags])
  end

  defp add_threading_options(command, nil), do: command

  defp add_threading_options(command, threading_opts) do
    command
    |> add_optional_file_option(&option_threads/1, threading_opts[:threads])
  end

  defp add_optional_file_option(command, _option_func, nil), do: command

  defp add_optional_file_option(command, option_func, value) do
    add_file_option(command, option_func.(value))
  end

  defp add_optional_stream_option(command, _option_func, nil), do: command

  defp add_optional_stream_option(command, option_func, value) do
    add_stream_option(command, option_func.(value))
  end

  @spec execute_and_get_file_size(FFmpex.Command.t(), String.t()) :: ffmpeg_result()
  defp execute_and_get_file_size(command, output_path) do
    case FFmpex.execute(command) do
      {:ok, _output} ->
        # Verify the file was created and get its size
        case File.stat(output_path) do
          {:ok, %File.Stat{size: file_size}} ->
            {:ok, file_size}

          {:error, reason} ->
            {:error, "Created file not found: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("FFmpegRunner: FFmpeg execution failed: #{inspect(reason)}")
        {:error, "FFmpeg error: #{inspect(reason)}"}
    end
  end

  @spec parse_video_metadata(map()) :: metadata_result()
  defp parse_video_metadata(probe_data) do
    Logger.debug("FFmpegRunner: ffprobe result: #{inspect(probe_data)}")

    with {:ok, duration} <- extract_duration(probe_data),
         {:ok, fps} <- extract_fps(probe_data),
         {:ok, total_frames} <- extract_total_frames(probe_data, duration, fps),
         {:ok, width} <- extract_width(probe_data),
         {:ok, height} <- extract_height(probe_data) do
      if duration <= 0 or fps <= 0 or total_frames <= 0 or width <= 0 or height <= 0 do
        {:error,
         "Invalid video metadata: duration=#{duration}s, fps=#{fps}, frames=#{total_frames}, dimensions=#{width}x#{height}"}
      else
        metadata = %{
          duration: duration,
          fps: fps,
          total_frames: total_frames,
          width: width,
          height: height
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

  defp extract_width(%{"width" => width}) when is_integer(width) and width > 0 do
    {:ok, width}
  end

  defp extract_width(_), do: {:error, "Could not determine video width"}

  defp extract_height(%{"height" => height}) when is_integer(height) and height > 0 do
    {:ok, height}
  end

  defp extract_height(_), do: {:error, "Could not determine video height"}

  @doc """
  Extracts keyframes from video at specific timestamps using FFmpegConfig.

  Uses the single_frame profile for consistent JPEG quality settings.

  ## Parameters
  - `video_path`: Path to input video file
  - `output_dir`: Directory to save keyframe images
  - `timestamps`: List of timestamps in seconds (floats)
  - `opts`: Optional parameters
    - `:prefix` - Filename prefix (default: "keyframe")
    - `:quality` - JPEG quality override (default: from single_frame profile)

  ## Returns
  - `{:ok, keyframe_data}` with list of keyframe info maps
  - `{:error, reason}` on failure

  ## Examples

      {:ok, keyframes} = FFmpegRunner.extract_keyframes_by_timestamp(
        "/tmp/video.mp4",
        "/tmp/keyframes",
        [30.0, 60.0, 90.0],
        prefix: "clip_123"
      )
      # Returns: [{:ok, %{path: "/tmp/keyframes/clip_123_30.0.jpg", timestamp: 30.0, ...}}, ...]
  """
  @spec extract_keyframes_by_timestamp(String.t(), String.t(), [float()], keyword()) ::
          {:ok, [map()]} | {:error, any()}
  def extract_keyframes_by_timestamp(video_path, output_dir, timestamps, opts \\ []) do
    # Get single frame profile for consistent settings
    config = FFmpegConfig.get_profile_config(:single_frame)

    prefix = Keyword.get(opts, :prefix, "keyframe")
    quality = Keyword.get(opts, :quality, config.video[:quality] || "2")

    # Ensure output directory exists
    case File.mkdir_p(output_dir) do
      :ok ->
        extract_keyframes_at_timestamps(video_path, output_dir, timestamps, prefix, quality)

      {:error, reason} ->
        {:error, "Failed to create output directory: #{inspect(reason)}"}
    end
  end

  @doc """
  Extracts keyframes from video at specific percentage positions.

  First gets video duration, then calculates timestamps from percentages.

  ## Parameters
  - `video_path`: Path to input video file
  - `output_dir`: Directory to save keyframe images
  - `percentages`: List of percentages 0.0-1.0 (e.g., [0.25, 0.5, 0.75])
  - `opts`: Optional parameters (same as extract_keyframes_by_timestamp)

  ## Returns
  - `{:ok, keyframe_data}` with list of keyframe info maps
  - `{:error, reason}` on failure

  ## Examples

      {:ok, keyframes} = FFmpegRunner.extract_keyframes_by_percentage(
        "/tmp/video.mp4",
        "/tmp/keyframes",
        [0.25, 0.5, 0.75],
        prefix: "clip_123"
      )
  """
  @spec extract_keyframes_by_percentage(String.t(), String.t(), [float()], keyword()) ::
          {:ok, [map()]} | {:error, any()}
  def extract_keyframes_by_percentage(video_path, output_dir, percentages, opts \\ []) do
    with {:ok, metadata} <- get_video_metadata(video_path) do
      duration = Map.get(metadata, :duration, 0.0)

      if duration > 0 do
        timestamps = Enum.map(percentages, fn pct -> duration * pct end)
        extract_keyframes_by_timestamp(video_path, output_dir, timestamps, opts)
      else
        {:error, "Invalid video duration: #{duration}"}
      end
    end
  end

  ## Private keyframe extraction helpers

  @spec extract_keyframes_at_timestamps(String.t(), String.t(), [float()], String.t(), integer()) ::
          {:ok, [map()]} | {:error, any()}
  defp extract_keyframes_at_timestamps(video_path, output_dir, timestamps, prefix, quality) do
    Logger.info("FFmpegRunner: Extracting #{length(timestamps)} keyframes from #{video_path}")

    results =
      timestamps
      |> Enum.with_index()
      |> Enum.map(fn {timestamp, index} ->
        # Log progress for each keyframe extraction
        progress_percentage = trunc(index / length(timestamps) * 100)

        if progress_percentage > 0 and rem(progress_percentage, 25) == 0 do
          Logger.info(
            "Keyframe extraction: #{progress_percentage}% complete (#{index + 1}/#{length(timestamps)} keyframes)"
          )
        end

        extract_single_keyframe_at_timestamp(
          video_path,
          output_dir,
          timestamp,
          prefix,
          quality,
          index
        )
      end)

    # Check if any extractions failed
    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      nil ->
        Logger.info(
          "Keyframe extraction: 100% complete (#{length(timestamps)}/#{length(timestamps)} keyframes)"
        )

        {:ok, Enum.map(results, fn {:ok, keyframe_data} -> keyframe_data end)}

      {:error, reason} ->
        {:error, "Keyframe extraction failed: #{reason}"}
    end
  end

  @spec extract_single_keyframe_at_timestamp(
          String.t(),
          String.t(),
          float(),
          String.t(),
          integer(),
          integer()
        ) ::
          {:ok, map()} | {:error, any()}
  defp extract_single_keyframe_at_timestamp(
         video_path,
         output_dir,
         timestamp,
         prefix,
         quality,
         index
       ) do
    timestamp_str = Float.to_string(timestamp)
    filename = "#{prefix}_#{timestamp_str}.jpg"
    output_path = Path.join(output_dir, filename)

    try do
      command =
        FFmpex.new_command()
        |> add_input_file(video_path)
        |> add_file_option(option_ss(timestamp_str))
        |> add_output_file(output_path)
        |> add_file_option(option_vframes("1"))
        |> add_stream_specifier(stream_type: :video)
        |> add_stream_option(option_q(to_string(quality)))
        |> add_global_option(option_y())

      case FFmpex.execute(command) do
        {:ok, _output} ->
          case File.stat(output_path) do
            {:ok, %File.Stat{size: file_size}} when file_size > 0 ->
              Logger.debug("FFmpegRunner: Extracted keyframe at #{timestamp}s: #{filename}")

              {:ok,
               %{
                 path: output_path,
                 filename: filename,
                 timestamp: timestamp,
                 file_size: file_size,
                 index: index
               }}

            {:ok, %File.Stat{size: 0}} ->
              {:error, "Keyframe file is empty: #{output_path}"}

            {:error, reason} ->
              {:error, "Keyframe file not created: #{inspect(reason)}"}
          end

        {:error, reason} ->
          Logger.error(
            "FFmpegRunner: FFmpeg failed to extract keyframe at #{timestamp}s: #{inspect(reason)}"
          )

          {:error, "FFmpeg keyframe extraction failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error(
          "FFmpegRunner: Exception extracting keyframe at #{timestamp}s: #{inspect(e)}"
        )

        {:error, "Exception extracting keyframe: #{inspect(e)}"}
    end
  end
end
