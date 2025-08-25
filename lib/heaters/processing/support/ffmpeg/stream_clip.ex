defmodule Heaters.Processing.Support.FFmpeg.StreamClip do
  @moduledoc """
  Unified abstraction for efficient clip generation using FFmpeg stream copy.

  This module provides a consistent interface for generating both temporary and permanent clips
  using FFmpeg stream copy operations directly from CloudFront URLs. It eliminates the need
  for local file downloads while providing configurable profiles for different use cases.

  ## Key Features

  - **Zero Downloads**: Processes directly from CloudFront URLs using FFmpeg stream copy
  - **Profile-Based**: Uses FFmpeg configuration profiles for consistent, maintainable settings
  - **Fast Processing**: Stream copy provides 10x performance improvement vs re-encoding
  - **Quality Preservation**: Zero quality loss for permanent exports
  - **Browser Compatibility**: Optimized outputs for various playback contexts

  ## Supported Use Cases

  - **Temporary Clips**: Fast preview generation for review UI (no audio, small files)
  - **Final Exports**: High-quality permanent clips with audio preservation
  - **Custom Profiles**: Extensible via FFmpeg configuration system

  ## Architecture

  This module builds on the foundations laid by:
  - `Heaters.Storage.PlaybackCache.TempClip` - Original efficient implementation pattern
  - `Heaters.Processing.Support.FFmpeg.Config` - Profile-based configuration
  - `Heaters.Storage.S3.ClipUrlGenerator` - CloudFront URL generation

  ## Usage

      # Generate a temporary clip for browser preview
      {:ok, temp_url} = StreamClip.generate_clip(clip, :temp_playback)

      # Generate a final export clip with audio
      {:ok, s3_path} = StreamClip.generate_clip(clip, :final_export, output_path: "exports/clip_123.mp4")

  ## Error Handling

  Returns detailed error information including FFmpeg output for debugging:
  - `{:ok, result}` - Success with output path/URL
  - `{:error, reason}` - Failure with descriptive error message
  """

  require Logger

  alias Heaters.Processing.Support.FFmpeg.Config
  alias Heaters.Storage.S3.ClipUrlGenerator
  alias Heaters.Repo

  @ffmpeg_bin Application.compile_env(:heaters, :ffmpeg_bin, "/usr/bin/ffmpeg")
  @tmp_dir System.tmp_dir!()

  @type clip_data :: %{
          id: integer(),
          start_time_seconds: float(),
          end_time_seconds: float(),
          source_video: map()
        }

  @type generate_options :: keyword()

  @type generate_result :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Generate a clip using FFmpeg stream copy with the specified profile.

  ## Parameters

  - `clip`: Clip struct with timing and source video information
  - `profile`: FFmpeg profile atom (e.g., `:temp_playback`, `:final_export`)
  - `opts`: Generation options

  ## Options

  - `:output_path` - Custom output path (required for final exports)
  - `:upload_to_s3` - Whether to upload result to S3 (default: false for temp, true for final)
  - `:cache_buster` - Add timestamp to prevent browser caching (default: true for temp)
  - `:operation_name` - Name for logging (default: "StreamClip")

  ## Returns

  - `{:ok, path_or_url}` - Success with file path (for temp) or S3 path (for final)
  - `{:error, reason}` - Failure with error description

  ## Examples

      # Temporary clip for browser preview
      {:ok, "/temp/clip_123_456789.mp4?t=123456"} =
        StreamClip.generate_clip(clip, :temp_playback)

      # Final export with S3 upload
      {:ok, "clips/clip_123.mp4"} =
        StreamClip.generate_clip(clip, :final_export,
          output_path: "clips/clip_123.mp4",
          upload_to_s3: true)
  """
  @spec generate_clip(clip_data(), atom(), generate_options()) :: generate_result()
  def generate_clip(clip, profile, opts \\ []) do
    # Ensure clip has source_video preloaded
    with {:ok, clip_with_source} <- ensure_source_video_loaded(clip),
         {:ok, ffmpeg_args} <- get_profile_args(profile),
         {:ok, input_url} <- get_input_url(clip_with_source.source_video),
         {:ok, output_path} <- determine_output_path(clip_with_source, profile, opts),
         {:ok, result_path} <-
           execute_ffmpeg_command(clip_with_source, input_url, output_path, ffmpeg_args, opts) do
      handle_post_generation(result_path, profile, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  ## Private Implementation

  @spec ensure_source_video_loaded(clip_data()) :: {:ok, clip_data()} | {:error, String.t()}
  defp ensure_source_video_loaded(%{source_video: %{}} = clip), do: {:ok, clip}

  defp ensure_source_video_loaded(%{id: id} = _clip) do
    case Repo.get(Heaters.Media.Clip, id) do
      nil -> {:error, "Clip not found"}
      clip -> {:ok, Repo.preload(clip, :source_video)}
    end
  end

  @spec get_profile_args(atom()) :: {:ok, [String.t()]} | {:error, String.t()}
  defp get_profile_args(profile) do
    try do
      args = Config.get_args(profile)
      {:ok, args}
    rescue
      ArgumentError -> {:error, "Unknown FFmpeg profile: #{profile}"}
    end
  end

  @spec get_input_url(map()) :: {:ok, String.t()} | {:error, String.t()}
  defp get_input_url(%{proxy_filepath: proxy_filepath}) when not is_nil(proxy_filepath) do
    if Application.get_env(:heaters, :app_env) == "development" do
      # In development, try CloudFront URL first, fallback to local test file
      try do
        {:ok, url} = ClipUrlGenerator.generate_signed_cloudfront_url(proxy_filepath)
        {:ok, url}
      rescue
        _ ->
          Logger.warning("StreamClip: CloudFront URL failed, using local test proxy")
          get_local_test_proxy()
      end
    else
      # Production: use CloudFront URL
      ClipUrlGenerator.generate_signed_cloudfront_url(proxy_filepath)
    end
  end

  defp get_input_url(_), do: {:error, "No proxy_filepath available"}

  @spec get_local_test_proxy() :: {:ok, String.t()} | {:error, String.t()}
  defp get_local_test_proxy do
    priv_path = Application.app_dir(:heaters, "priv")
    local_file = Path.join([priv_path, "fixtures", "proxy_local.mp4"])

    if File.exists?(local_file) do
      {:ok, local_file}
    else
      {:error, "Local test proxy file not found: #{local_file}"}
    end
  end

  @spec determine_output_path(clip_data(), atom(), generate_options()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp determine_output_path(clip, :temp_playback, _opts) do
    # Generate unique temp file path with timestamp
    timestamp = System.system_time(:millisecond)
    filename = "clip_#{clip.id}_#{timestamp}.mp4"
    {:ok, Path.join(@tmp_dir, filename)}
  end

  defp determine_output_path(_clip, _profile, opts) do
    case Keyword.get(opts, :output_path) do
      nil ->
        {:error, "output_path required for non-temp profiles"}

      path ->
        # For non-temp profiles, use a local temp file first
        # The S3 upload will happen in post-processing
        filename = Path.basename(path)
        local_path = Path.join(@tmp_dir, filename)
        {:ok, local_path}
    end
  end

  @spec execute_ffmpeg_command(
          clip_data(),
          String.t(),
          String.t(),
          [String.t()],
          generate_options()
        ) ::
          {:ok, String.t()} | {:error, String.t()}
  defp execute_ffmpeg_command(clip, input_url, output_path, profile_args, opts) do
    operation_name = Keyword.get(opts, :operation_name, "StreamClip")

    duration_seconds = clip.end_time_seconds - clip.start_time_seconds

    # Build complete FFmpeg command
    cmd_args =
      build_ffmpeg_command(
        input_url,
        output_path,
        clip.start_time_seconds,
        duration_seconds,
        profile_args
      )

    Logger.info(
      "#{operation_name}: Generating clip #{clip.id} (#{clip.start_time_seconds}s-#{clip.end_time_seconds}s, #{Float.round(duration_seconds, 2)}s duration)"
    )

    Logger.debug("#{operation_name}: FFmpeg command: #{@ffmpeg_bin} #{Enum.join(cmd_args, " ")}")

    try do
      case System.cmd(@ffmpeg_bin, cmd_args, stderr_to_stdout: true) do
        {_output, 0} ->
          if File.exists?(output_path) do
            file_size = File.stat!(output_path).size
            Logger.info("#{operation_name}: Generated #{output_path} (#{file_size} bytes)")

            if file_size < 10_000 do
              Logger.warning(
                "#{operation_name}: Generated file is suspiciously small (#{file_size} bytes)"
              )
            end

            {:ok, output_path}
          else
            Logger.error(
              "#{operation_name}: FFmpeg reported success but file doesn't exist: #{output_path}"
            )

            {:error, "FFmpeg completed but no output file created"}
          end

        {error_output, exit_code} ->
          Logger.error("#{operation_name}: FFmpeg failed (exit #{exit_code}): #{error_output}")
          {:error, "FFmpeg failed: #{error_output}"}
      end
    catch
      :exit, {:timeout, _} ->
        Logger.error("#{operation_name}: FFmpeg timeout - network or processing issue")
        {:error, "FFmpeg timeout - network or processing issue"}
    end
  end

  @spec build_ffmpeg_command(String.t(), String.t(), float(), float(), [String.t()]) :: [
          String.t()
        ]
  defp build_ffmpeg_command(input_url, output_path, start_seconds, duration_seconds, profile_args) do
    [
      # Standard FFmpeg options
      "-hide_banner",
      "-loglevel",
      "error",
      # Overwrite output files
      "-y",

      # Timing (seek before input for better accuracy)
      "-ss",
      Float.to_string(start_seconds),

      # Input
      "-i",
      input_url,

      # Duration
      "-t",
      Float.to_string(duration_seconds)
    ] ++ profile_args ++ [output_path]
  end

  @spec handle_post_generation(String.t(), atom(), generate_options()) :: generate_result()
  defp handle_post_generation(file_path, :temp_playback, opts) do
    # For temp clips, return HTTP URL for browser access
    operation_name = Keyword.get(opts, :operation_name, "StreamClip")
    cache_buster = Keyword.get(opts, :cache_buster, true)

    filename = Path.basename(file_path)

    url =
      if cache_buster do
        timestamp = System.system_time(:second)
        "/temp/#{filename}?t=#{timestamp}"
      else
        "/temp/#{filename}"
      end

    Logger.debug("#{operation_name}: Temp clip available at #{url}")
    {:ok, url}
  end

  defp handle_post_generation(file_path, _profile, opts) do
    # For permanent clips, handle S3 upload if requested
    upload_to_s3 = Keyword.get(opts, :upload_to_s3, true)
    operation_name = Keyword.get(opts, :operation_name, "StreamClip")

    if upload_to_s3 do
      s3_output_path = Keyword.get(opts, :output_path)
      # Cache locally for downstream stages (e.g., Keyframe) to avoid immediate re-download
      # Best-effort: ignore caching errors to not block export
      try do
        Heaters.Storage.PipelineCache.TempCache.put(s3_output_path, file_path)
      rescue
        _ -> :ok
      end

      case Heaters.Storage.S3.Core.upload_file(file_path, s3_output_path,
             operation_name: operation_name
           ) do
        {:ok, s3_key} ->
          Logger.debug("#{operation_name}: Uploaded to S3: #{s3_key}")

          # Clean up local file
          File.rm(file_path)

          {:ok, s3_key}

        {:error, reason} ->
          {:error, "S3 upload failed: #{reason}"}
      end
    else
      {:ok, file_path}
    end
  end
end
