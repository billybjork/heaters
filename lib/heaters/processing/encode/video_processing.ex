defmodule Heaters.Processing.Encode.VideoProcessing do
  @moduledoc """
  Core video processing operations for proxy and master file creation.

  Uses existing FFmpeg infrastructure for all video operations:
  - `Heaters.Processing.Support.FFmpeg.Config` for encoding profiles
  - FFmpex for command building and execution with progress reporting
  """

  require Logger
  import FFmpex
  use FFmpex.Options

  alias Heaters.Processing.Support.FFmpeg.Config
  alias Heaters.Processing.Encode.MetadataExtraction

  @type video_result :: {:ok, map()} | {:error, String.t()}

  @doc """
  Create a proxy video file with smart reuse optimization.

  If reuse is enabled and the source is suitable, copies the source directly.
  Otherwise, encodes a new proxy using the specified profile.
  """
  @spec create_proxy_file(
          String.t(),
          String.t(),
          map(),
          atom(),
          boolean(),
          String.t(),
          String.t()
        ) :: video_result()
  def create_proxy_file(
        source_path,
        output_s3_path,
        metadata,
        profile,
        reuse_source,
        work_dir,
        operation_name
      ) do
    proxy_local_path = Path.join(work_dir, "proxy.mp4")

    Logger.info("#{operation_name}: Creating proxy file using profile: #{profile}")

    if reuse_source && MetadataExtraction.can_reuse_as_proxy?(metadata) do
      Logger.info("#{operation_name}: Reusing source file as proxy (smart optimization)")

      case File.cp(source_path, proxy_local_path) do
        :ok ->
          # Extract keyframes from the reused proxy
          keyframe_offsets = MetadataExtraction.extract_keyframe_offsets(proxy_local_path, operation_name)

          {:ok,
           %{
             local_path: proxy_local_path,
             s3_path: output_s3_path,
             keyframe_offsets: keyframe_offsets,
             reused_source: true
           }}

        {:error, reason} ->
          Logger.error(
            "#{operation_name}: Failed to copy source for proxy reuse: #{inspect(reason)}"
          )

          {:error, "Failed to copy source for proxy reuse: #{inspect(reason)}"}
      end
    else
      # Create new proxy using FFmpeg encoding
      create_encoded_video(
        source_path,
        proxy_local_path,
        output_s3_path,
        metadata,
        profile,
        "proxy",
        operation_name
      )
      |> add_keyframe_offsets(operation_name)
    end
  end

  @doc """
  Create a master video file with archival-quality encoding.

  Creates a high-quality master file for long-term storage.
  """
  @spec create_master_file(
          String.t(),
          String.t(),
          map(),
          atom(),
          boolean(),
          String.t(),
          String.t()
        ) :: video_result()
  def create_master_file(
        source_path,
        output_s3_path,
        metadata,
        profile,
        skip_creation,
        work_dir,
        operation_name
      ) do
    if skip_creation do
      Logger.info("#{operation_name}: Skipping master file creation (cost optimization)")
      {:ok, %{s3_path: nil, local_path: nil, skipped: true}}
    else
      master_local_path = Path.join(work_dir, "master.mp4")

      Logger.info("#{operation_name}: Creating master file using profile: #{profile}")

      create_encoded_video(
        source_path,
        master_local_path,
        output_s3_path,
        metadata,
        profile,
        "master",
        operation_name
      )
    end
  end

  # Private helper functions

  # Create encoded video using FFmpeg with progress reporting
  @spec create_encoded_video(String.t(), String.t(), String.t(), map(), atom(), String.t(), String.t()) ::
          video_result()
  defp create_encoded_video(
         source_path,
         local_output_path,
         s3_output_path,
         metadata,
         profile,
         video_type,
         operation_name
       ) do
    config = Config.get_profile_config(profile)
    duration = Map.get(metadata, :duration, 0.0)

    Logger.info("#{operation_name}: Encoding #{video_type} with duration: #{duration}s")

    # Build FFmpeg command using configuration
    command = build_ffmpeg_command(source_path, local_output_path, config)

    case execute_ffmpeg_with_progress(command, duration, "#{String.capitalize(video_type)} Creation", operation_name) do
      {:ok, _} ->
        case File.stat(local_output_path) do
          {:ok, %File.Stat{size: file_size}} when file_size > 0 ->
            Logger.info("#{operation_name}: #{String.capitalize(video_type)} created successfully: #{file_size} bytes")

            result = %{
              local_path: local_output_path,
              s3_path: s3_output_path,
              skipped: false
            }

            {:ok, result}

          {:ok, %File.Stat{size: 0}} ->
            {:error, "#{String.capitalize(video_type)} file is empty: #{local_output_path}"}

          {:error, reason} ->
            {:error, "#{String.capitalize(video_type)} file not created: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "FFmpeg #{video_type} creation failed: #{reason}"}
    end
  end

  # Add keyframe offsets to proxy result
  @spec add_keyframe_offsets(video_result(), String.t()) :: video_result()
  defp add_keyframe_offsets({:ok, result}, operation_name) do
    keyframe_offsets = MetadataExtraction.extract_keyframe_offsets(result.local_path, operation_name)
    
    updated_result = Map.merge(result, %{
      keyframe_offsets: keyframe_offsets,
      reused_source: false
    })
    
    {:ok, updated_result}
  end

  defp add_keyframe_offsets({:error, reason}, _operation_name), do: {:error, reason}

  # Build FFmpeg command for encoding
  @spec build_ffmpeg_command(String.t(), String.t(), map()) :: FFmpex.Command.t()
  defp build_ffmpeg_command(input_path, output_path, config) do
    FFmpex.new_command()
    |> add_input_file(input_path)
    |> add_output_file(output_path)
    |> add_profile_encoding_options(config)
    |> add_global_option(option_y())
  end

  # Add profile encoding options to FFmpeg command (similar to existing Runner implementation)
  @spec add_profile_encoding_options(FFmpex.Command.t(), map()) :: FFmpex.Command.t()
  defp add_profile_encoding_options(command, config) do
    command
    |> add_video_encoding_options(config.video)
    |> add_audio_encoding_options(config[:audio])
    |> add_web_optimization_options(config[:web_optimization])
  end

  defp add_video_encoding_options(command, video_config) do
    command
    |> add_stream_specifier(stream_type: :video)
    |> add_stream_option(option_c(video_config.codec))
    |> add_optional_stream_option(&option_preset/1, video_config[:preset])
    |> add_optional_stream_option(&option_crf/1, video_config[:crf])
    |> add_optional_stream_option(&option_pix_fmt/1, video_config[:pix_fmt])
    |> add_optional_stream_option(&option_g/1, video_config[:gop_size])
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

  defp add_optional_stream_option(command, _option_func, nil), do: command

  defp add_optional_stream_option(command, option_func, value) do
    add_stream_option(command, option_func.(value))
  end

  defp add_optional_file_option(command, _option_func, nil), do: command

  defp add_optional_file_option(command, option_func, value) do
    add_file_option(command, option_func.(value))
  end

  # Execute FFmpeg with progress reporting
  @spec execute_ffmpeg_with_progress(FFmpex.Command.t(), float(), String.t(), String.t()) ::
          {:ok, any()} | {:error, String.t()}
  defp execute_ffmpeg_with_progress(command, duration, task_name, operation_name) do
    Logger.info("#{operation_name}: Starting #{task_name}")

    # Convert FFmpex command to raw arguments for progress monitoring
    case ffmpeg_command_to_args(command) do
      {:ok, args} ->
        execute_ffmpeg_with_real_progress(args, duration, task_name, operation_name)

      {:error, reason} ->
        Logger.error("#{operation_name}: Failed to build FFmpeg command: #{inspect(reason)}")
        {:error, "Failed to build FFmpeg command: #{inspect(reason)}"}
    end
  end

  # Convert FFmpex command to raw FFmpeg arguments
  @spec ffmpeg_command_to_args(FFmpex.Command.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  defp ffmpeg_command_to_args(command) do
    try do
      case FFmpex.prepare(command) do
        {_executable, args} -> {:ok, args}
      end
    rescue
      error ->
        {:error, "FFmpex command preparation failed: #{Exception.message(error)}"}
    end
  end

  # Execute FFmpeg with real-time progress reporting
  @spec execute_ffmpeg_with_real_progress([String.t()], float(), String.t(), String.t()) ::
          {:ok, any()} | {:error, String.t()}
  defp execute_ffmpeg_with_real_progress(args, duration, task_name, operation_name) do
    # Add progress reporting to stderr
    args_with_progress = args ++ ["-progress", "pipe:2"]

    Logger.info("#{operation_name}: #{task_name} with duration: #{duration}s")

    # Use Port for real-time stderr processing
    port_opts = [
      :stderr_to_stdout,
      :exit_status,
      :binary,
      :use_stdio,
      args: args_with_progress
    ]

    port = Port.open({:spawn_executable, System.find_executable("ffmpeg")}, port_opts)

    result = monitor_ffmpeg_progress(port, duration, task_name, operation_name, "")

    case result do
      {:ok, _} ->
        Logger.info("#{operation_name}: #{task_name} completed successfully")
        {:ok, nil}

      {:error, reason} ->
        Logger.error("#{operation_name}: #{task_name} failed: #{reason}")
        {:error, "#{task_name} failed: #{reason}"}
    end
  rescue
    error ->
      Logger.error("#{operation_name}: #{task_name} exception: #{Exception.message(error)}")
      {:error, "#{task_name} exception: #{Exception.message(error)}"}
  end

  # Monitor FFmpeg progress by parsing stderr output (entry point)
  @spec monitor_ffmpeg_progress(port(), float(), String.t(), String.t(), String.t()) ::
          {:ok, any()} | {:error, String.t()}
  defp monitor_ffmpeg_progress(port, duration, task_name, operation_name, buffer) do
    monitor_ffmpeg_progress_with_state(port, duration, task_name, operation_name, buffer, 0)
  end

  # Internal function with progress state tracking
  @spec monitor_ffmpeg_progress_with_state(
          port(),
          float(),
          String.t(),
          String.t(),
          String.t(),
          integer()
        ) ::
          {:ok, any()} | {:error, String.t()}
  defp monitor_ffmpeg_progress_with_state(
         port,
         duration,
         task_name,
         operation_name,
         buffer,
         last_progress
       ) do
    receive do
      {^port, {:data, data}} ->
        new_buffer = buffer <> data
        {processed_lines, remaining_buffer} = extract_complete_lines(new_buffer)

        new_last_progress =
          Enum.reduce(processed_lines, last_progress, fn line, acc_progress ->
            parse_and_log_progress(line, duration, task_name, operation_name, acc_progress)
          end)

        monitor_ffmpeg_progress_with_state(
          port,
          duration,
          task_name,
          operation_name,
          remaining_buffer,
          new_last_progress
        )

      {^port, {:exit_status, 0}} ->
        Logger.info("#{operation_name}: #{task_name} (100% complete)")
        {:ok, :success}

      {^port, {:exit_status, exit_code}} ->
        {:error, "FFmpeg exited with code #{exit_code}"}
    after
      30 * 60 * 1000 ->
        Port.close(port)
        {:error, "FFmpeg operation timed out after 30 minutes"}
    end
  end

  # Extract complete lines from buffer
  @spec extract_complete_lines(String.t()) :: {[String.t()], String.t()}
  defp extract_complete_lines(buffer) do
    lines = String.split(buffer, "\n")

    case List.pop_at(lines, -1) do
      {remaining_buffer, complete_lines} ->
        {complete_lines, remaining_buffer || ""}
    end
  end

  # Parse progress lines and log percentage updates
  @spec parse_and_log_progress(String.t(), float(), String.t(), String.t(), integer()) ::
          integer()
  defp parse_and_log_progress(line, duration, task_name, operation_name, last_progress) do
    if String.contains?(line, "out_time=") && duration > 0 do
      case extract_time_from_progress_line(line) do
        {:ok, current_seconds} ->
          progress = min(100, trunc(current_seconds / duration * 100))

          if progress > 0 && progress >= last_progress + 10 && rem(progress, 10) == 0 do
            Logger.info("#{operation_name}: #{task_name} #{progress}% complete")
            progress
          else
            last_progress
          end

        :error ->
          last_progress
      end
    else
      last_progress
    end
  end

  # Extract time from FFmpeg progress line (out_time=00:01:23.45)
  @spec extract_time_from_progress_line(String.t()) :: {:ok, float()} | :error
  defp extract_time_from_progress_line(line) do
    case Regex.run(~r/out_time=(\d{2}:\d{2}:\d{2}\.\d+)/, line) do
      [_, time_str] ->
        parse_time_string(time_str)

      nil ->
        :error
    end
  end

  # Parse time string in format HH:MM:SS.mmm to seconds
  @spec parse_time_string(String.t()) :: {:ok, float()} | :error
  defp parse_time_string(time_str) do
    try do
      case String.split(time_str, ":") do
        [hours_str, minutes_str, seconds_str] ->
          hours = parse_numeric(hours_str)
          minutes = parse_numeric(minutes_str)
          seconds = parse_numeric(seconds_str)
          total_seconds = hours * 3600 + minutes * 60 + seconds
          {:ok, total_seconds}

        _ ->
          :error
      end
    rescue
      _ ->
        :error
    end
  end

  # Helper to parse numeric strings that could be integers or floats
  @spec parse_numeric(String.t()) :: float()
  defp parse_numeric(str) do
    case String.contains?(str, ".") do
      true -> String.to_float(str)
      false -> String.to_integer(str) / 1.0
    end
  end
end