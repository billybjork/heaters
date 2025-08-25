defmodule Heaters.Processing.Support.FFmpeg.Config do
  @moduledoc """
  Centralized FFmpeg configuration for all video processing operations.

  Defines encoding profiles as declarative data structures, making FFmpeg arguments
  consistent, maintainable, and easy to configure across the entire pipeline.

  Each profile is optimized for its specific use case:
  - **master**: High-quality archival with pragmatic storage efficiency (CRF 18 H.264)
  - **proxy**: Minimal file size with I-frame seeking for internal review UI
  - **download_normalization**: Lightweight fixing of merge issues
  - **keyframe_extraction**: Efficient single-frame extraction

  ## Storage Strategy

  **Master**: High-quality H.264 (CRF 18) stored in S3 Standard for instant access.
  Balances archival quality with storage costs—visually lossless with reasonable file sizes.
  Much more efficient than lossless formats while preserving excellent quality.

  **Proxy**: Optimized for internal review UI with significant file size reduction:
  - Resolution capped at 720p for smaller files
  - CRF 28 for acceptable quality with major size reduction
  - All I-frame encoding preserved for frame-by-frame navigation
  - Used as source for instant temp clip generation via stream copy

  **Export Strategy**: Final clips are created via FFmpeg stream copy from proxy,
  providing fast processing optimized for internal review workflows.

  ## Usage in Elixir

      args = FFmpegConfig.get_args(:proxy)
      # Returns: ["-c:v", "libx264", "-preset", "medium", ...]

  ## Usage in Python Tasks

  Python tasks receive pre-built argument lists via task parameters, eliminating
  the need for hardcoded FFmpeg settings in Python code.

      # In worker:
      PyRunner.run_task("encode", %{
        master_args: FFmpegConfig.get_args(:master),
        proxy_args: FFmpegConfig.get_args(:proxy),
        ...
      })
  """

  @doc """
  Returns FFmpeg argument list for the specified encoding profile.

  ## Parameters
  - `profile`: Atom identifying the encoding profile
  - `opts`: Optional parameters for profile customization
    - `:skip_master`: Skip master generation (returns empty args for :master profile)
    - `:crf`: Override CRF value
    - `:preset`: Override preset
    - `:audio_bitrate`: Override audio bitrate
    - `:threads`: Override thread count
    - `:no_audio`: Remove audio streams entirely (sets -an flag)

  ## Examples

      iex> FFmpegConfig.get_args(:master)
      ["-c:v", "ffv1", "-level", "3", "-coder", "1", ...]

      iex> FFmpegConfig.get_args(:master, skip_master: true)
      []

      iex> FFmpegConfig.get_args(:proxy, crf: 25)
      ["-c:v", "libx264", "-preset", "fast", "-crf", "25", ...]

      iex> FFmpegConfig.get_args(:proxy, no_audio: true)
      ["-c:v", "libx264", "-preset", "fast", "-crf", "28", "-an", ...]
  """
  @spec get_args(atom(), keyword()) :: [String.t()]
  def get_args(profile, opts \\ []) do
    # Quick return for skipped master generation
    if profile == :master and Keyword.get(opts, :skip_master, false) do
      []
    else
      profile
      |> get_profile_config()
      |> apply_options(opts)
      |> build_ffmpeg_args()
    end
  end

  @doc """
  Returns the complete profile configuration as a map.

  Useful for debugging, logging, or when you need access to individual settings.
  """
  @spec get_profile_config(atom()) :: map()
  def get_profile_config(profile) do
    profiles()[profile] || raise ArgumentError, "Unknown FFmpeg profile: #{profile}"
  end

  @doc """
  Returns all available profile names.
  """
  @spec available_profiles() :: [atom()]
  def available_profiles do
    Map.keys(profiles())
  end

  @doc """
  Checks if master generation should be skipped based on configuration or feature flags.

  This allows for cost optimization by skipping expensive lossless master generation
  when not needed for immediate use cases.

  ## Parameters
  - `opts`: Options that may contain skip_master flag
  - `source_video`: Optional source video struct to make intelligent decisions

  ## Examples

      iex> FFmpegConfig.should_skip_master?(skip_master: true)
      true

      iex> FFmpegConfig.should_skip_master?([])
      false
  """
  @spec should_skip_master?(keyword(), map() | nil) :: boolean()
  def should_skip_master?(opts, _source_video \\ nil) do
    cond do
      # Explicit override
      Keyword.has_key?(opts, :skip_master) ->
        Keyword.get(opts, :skip_master, false)

      # Check application config for default behavior
      Application.get_env(:heaters, :skip_master_by_default, false) ->
        true

      # Could add more intelligent logic here based on source_video properties
      # For example: skip for videos shorter than X seconds, or specific sources

      true ->
        false
    end
  end

  @doc """
  Returns profile documentation for debugging/inspection.
  """
  @spec profile_info(atom()) :: map()
  def profile_info(profile) do
    config = get_profile_config(profile)

    %{
      profile: profile,
      purpose: config.purpose,
      video_codec: config.video.codec,
      audio_codec: config.audio.codec,
      container: config.container,
      optimization: config.optimization
    }
  end

  ## Private Implementation

  @spec profiles() :: map()
  defp profiles do
    %{
      # High-quality archival master optimized for pragmatic storage costs
      master: %{
        purpose: "High-quality archival master optimized for storage efficiency",
        optimization: "Visually lossless quality with reasonable file sizes",
        video: %{
          codec: "libx264",
          # Balanced encoding speed
          preset: "medium",
          # Visually lossless for most content, much smaller than FFV1
          crf: "18",
          pix_fmt: "yuv420p",
          # Use GOP for better compression (not all I-frames like proxy)
          gop_size: "250",
          # Enable B-frames for better compression
          bframes: "3",
          # High profile for better compression
          profile: "high",
          level: "4.1"
        },
        audio: %{
          # High quality audio, not lossless
          codec: "aac",
          bitrate: "256k"
        },
        # MP4 container for universal compatibility
        container: "mp4",
        threading: %{
          threads: "auto"
        },
        web_optimization: %{
          # Basic optimization for potential streaming
          movflags: "+faststart"
        }
      },

      # Optimized proxy for internal review UI with minimal file size
      proxy: %{
        purpose:
          "Optimized proxy for internal review UI with minimal file size and I-frame seeking",
        optimization: "Minimal file size while preserving frame-by-frame navigation",
        video: %{
          codec: "libx264",
          # Fast encoding for temp clip generation
          preset: "fast",
          # Higher CRF for smaller files (acceptable quality loss for internal review)
          crf: "28",
          # Reduced resolution for smaller files (720p max for review)
          scale: "min(1280\\,iw):min(720\\,ih):force_original_aspect_ratio=decrease",
          pix_fmt: "yuv420p",
          # All intraframes for perfect seeking
          gop_size: "1",
          # Minimum keyframe interval
          keyint_min: "1",
          # Disable scene change detection
          sc_threshold: "0",
          # Force baseline profile for universal compatibility
          profile: "baseline",
          level: "3.1",
          # Optimize for speed over compression efficiency
          tune: "fastdecode"
        },
        audio: %{
          codec: "aac",
          # Lower quality audio for review (can be muted via no_audio option)
          bitrate: "64k"
        },
        container: "mp4",
        web_optimization: %{
          # Optimize for instant playback and temp clip generation
          movflags: "+faststart"
        }
      },

      # Lightweight normalization to fix yt-dlp merge issues
      download_normalization: %{
        purpose: "Lightweight normalization to fix yt-dlp merge issues",
        optimization: "Minimal re-encoding to fix merge problems",
        video: %{
          codec: "libx264",
          # Speed over compression for normalization
          preset: "fast",
          # Good quality
          crf: "23",
          pix_fmt: "yuv420p"
        },
        audio: %{
          codec: "aac",
          bitrate: "128k"
        },
        container: "mp4",
        web_optimization: %{
          movflags: "+faststart"
        }
      },

      # Efficient encoding for clip creation operations
      keyframe_extraction: %{
        purpose: "Efficient encoding for clip creation operations",
        optimization: "Speed and resource efficiency for internal operations",
        video: %{
          codec: "libx264",
          # Lower CPU usage
          preset: "fast",
          # Lower quality but faster encoding
          crf: "25",
          pix_fmt: "yuv420p"
        },
        audio: %{
          codec: "aac",
          bitrate: "128k"
        },
        container: "mp4",
        web_optimization: %{
          movflags: "+faststart"
        },
        threading: %{
          # Conservative threading for 4K video
          threads: "2"
        }
      },

      # Single frame extraction for keyframes
      single_frame: %{
        purpose: "Single frame extraction for keyframes",
        optimization: "Quality and speed for JPEG extraction",
        video: %{
          # Single frame only
          vframes: "1",
          # JPEG quality (1-31, lower is better)
          quality: "2"
        },
        # Image output
        container: "image2"
      },

      # Temporary clip generation for instant playback and split-mode navigation
      # Uses stream copy from all-I proxies; no re-encode
      temp_playback: %{
        purpose: "Temp clip for review (split-mode ready)",
        optimization: "Stream copy from proxy; instant and seekable",
        video: %{
          codec: "copy",
          # don't force CFR; use DB fps only if you *need* to re-encode someday
          framerate: nil
        },
        # keep temp clips silent to save bytes
        no_audio: true,
        container: "mp4",
        web_optimization: %{
          movflags: "+faststart",
          avoid_negative_ts: "make_zero"
        }
      },

      # Final export for permanent clips using stream copy with audio preservation
      final_export: %{
        purpose: "Final export for permanent clips using stream copy",
        optimization: "Fast stream copy preserving original quality and audio",
        video: %{
          # Stream copy for maximum speed and zero quality loss
          codec: "copy"
        },
        audio: %{
          # Stream copy audio to preserve original quality
          codec: "copy"
        },
        container: "mp4",
        web_optimization: %{
          # Optimize for streaming/download
          movflags: "+faststart",
          # Clean timestamps
          avoid_negative_ts: "make_zero"
        }
      }
    }
  end

  @spec apply_options(map(), keyword()) :: map()
  defp apply_options(config, []), do: config

  defp apply_options(config, opts) do
    # Allow runtime customization of key parameters
    config
    |> maybe_update_crf(opts[:crf])
    |> maybe_update_preset(opts[:preset])
    |> maybe_update_audio_bitrate(opts[:audio_bitrate])
    |> maybe_update_threads(opts[:threads])
    |> maybe_disable_audio(opts[:no_audio])
    |> maybe_set_framerate(opts[:fps])
  end

  defp maybe_update_crf(config, nil), do: config

  defp maybe_update_crf(config, crf) when is_integer(crf) do
    put_in(config, [:video, :crf], to_string(crf))
  end

  defp maybe_update_preset(config, nil), do: config

  defp maybe_update_preset(config, preset) when is_binary(preset) do
    put_in(config, [:video, :preset], preset)
  end

  defp maybe_update_audio_bitrate(config, nil), do: config

  defp maybe_update_audio_bitrate(config, bitrate) when is_binary(bitrate) do
    put_in(config, [:audio, :bitrate], bitrate)
  end

  defp maybe_update_threads(config, nil), do: config

  defp maybe_update_threads(config, threads) when is_integer(threads) do
    put_in(config, [:threading, :threads], to_string(threads))
  end

  defp maybe_disable_audio(config, nil), do: config
  defp maybe_disable_audio(config, false), do: config

  defp maybe_disable_audio(config, true) do
    # Remove audio configuration and set no_audio flag
    config
    |> Map.delete(:audio)
    |> Map.put(:no_audio, true)
  end

  defp maybe_set_framerate(config, nil), do: config

  defp maybe_set_framerate(config, fps) when is_number(fps) do
    # Don't set framerate for stream copy - it can cause issues
    if get_in(config, [:video, :codec]) == "copy" do
      config
    else
      fps_float = if is_integer(fps), do: fps * 1.0, else: fps
      put_in(config, [:video, :framerate], to_string(Float.round(fps_float, 3)))
    end
  end

  @spec build_ffmpeg_args(map()) :: [String.t()]
  defp build_ffmpeg_args(config) do
    []
    |> add_video_args(config.video)
    |> add_audio_args(config[:audio], config[:no_audio])
    |> add_container_args(config.container)
    |> add_web_optimization_args(config[:web_optimization])
    |> add_threading_args(config[:threading])
  end

  defp add_video_args(args, video_config) do
    args
    |> add_if_present(["-c:v", video_config.codec])
    |> add_if_present(["-preset", video_config[:preset]])
    |> add_if_present(["-crf", video_config[:crf]])
    |> add_if_present(["-r", video_config[:framerate]])
    |> add_scale_filter(video_config[:scale])
    |> add_if_present(["-pix_fmt", video_config[:pix_fmt]])
    |> add_if_present(["-g", video_config[:gop_size]])
    |> add_if_present(["-keyint_min", video_config[:keyint_min]])
    |> add_if_present(["-sc_threshold", video_config[:sc_threshold]])
    |> add_if_present(["-bf", video_config[:bframes]])
    |> add_if_present(["-profile:v", video_config[:profile]])
    |> add_if_present(["-level", video_config[:level]])
    |> add_if_present(["-tune", video_config[:tune]])
    |> add_if_present(["-force_key_frames", video_config[:force_key_frames]])
    |> add_if_present(["-coder", video_config[:coder]])
    |> add_if_present(["-context", video_config[:context]])
    |> add_if_present(["-slices", video_config[:slices]])
    |> add_if_present(["-slicecrc", video_config[:slicecrc]])
    |> add_if_present(["-vframes", video_config[:vframes]])
    |> add_if_present(["-q:v", video_config[:quality]])
  end

  defp add_audio_args(args, nil, no_audio), do: maybe_add_no_audio(args, no_audio)
  defp add_audio_args(args, _audio_config, true), do: args ++ ["-an"]

  defp add_audio_args(args, audio_config, _no_audio) do
    args
    |> add_if_present(["-c:a", audio_config.codec])
    |> add_if_present(["-b:a", audio_config[:bitrate]])
  end

  defp maybe_add_no_audio(args, true), do: args ++ ["-an"]
  defp maybe_add_no_audio(args, _), do: args

  defp add_container_args(args, container) do
    args ++ ["-f", container]
  end

  defp add_web_optimization_args(args, nil), do: args

  defp add_web_optimization_args(args, web_opts) do
    args
    |> add_if_present(["-movflags", web_opts[:movflags]])
    |> add_if_present(["-avoid_negative_ts", web_opts[:avoid_negative_ts]])
    |> add_if_present(["-frag_duration", web_opts[:frag_duration]])
    |> add_if_present(["-min_frag_duration", web_opts[:min_frag_duration]])
  end

  defp add_threading_args(args, nil), do: args

  defp add_threading_args(args, threading_opts) do
    args
    |> add_if_present(["-threads", threading_opts[:threads]])
  end

  defp add_scale_filter(args, nil), do: args

  defp add_scale_filter(args, scale) when is_binary(scale) do
    args ++ ["-vf", "scale=#{scale}"]
  end

  defp add_if_present(args, addition) when is_list(addition) do
    case addition do
      [_key, nil] -> args
      [_key, value] when value in ["", 0] -> args
      valid_addition -> args ++ valid_addition
    end
  end
end
