defmodule Heaters.Processing.Download.YtDlpConfig do
  @moduledoc """
  Centralized yt-dlp configuration for quality-focused video downloads.

  Defines download strategies as declarative data structures, making yt-dlp
  arguments consistent, maintainable, and easy to test across the entire pipeline.

  Each strategy is optimized for its specific use case:
  - **primary**: Best quality with separate streams (4K/8K capable, may need normalization)
  - **fallback1**: Compatible MP4 format for maximum compatibility
  - **fallback2**: Worst quality for absolute maximum compatibility

  ## Quality Strategy

  **Primary Format**: Uses 'bv*+ba/b' for maximum quality downloads including 4K/8K.
  May require normalization to fix merge issues from separate video/audio streams.

  **Fallback Strategy**: Progressive degradation through compatible formats to ensure
  successful downloads even on restricted platforms.

  ## Usage in Elixir

      config = YtDlpConfig.get_download_config()
      # Returns complete configuration map with all strategies and options

  ## Usage in Python Tasks

  Python tasks receive pre-built configuration via task parameters, eliminating
  the need for hardcoded yt-dlp settings in Python code.

      # In worker:
      PyRunner.run("download", %{
        download_config: YtDlpConfig.get_download_config(),
        normalize_args: FFmpegConfig.get_args(:download_normalization),
        ...
      })

  ## Critical Quality Requirements

  🚨 This configuration implements 4K/8K quality downloads. To maintain this capability:

  ❌ NEVER ADD height restrictions to format strings (e.g., [height<=1080])
  ❌ NEVER ADD client restrictions via extractor_args
  ❌ NEVER ADD quality caps or manual limitations
  ❌ NEVER ADD extension restrictions to primary format (blocks VP9/AV1 4K)

  ✅ ALWAYS use unrestricted format strings
  ✅ ALWAYS let yt-dlp choose optimal clients automatically
  ✅ ALWAYS test with expected ~49 formats and 80MB+ downloads
  ✅ ALWAYS use three-tier fallback strategy

  Breaking these rules reduces quality from 4K to 360p (verified multiple times).
  """

  @doc """
  Returns complete yt-dlp download configuration.

  ## Parameters
  - `opts`: Optional parameters for configuration customization
    - `:timeout_multiplier`: Multiply all timeouts by this factor (default: 1.0)
    - `:disable_fallbacks`: Only use primary format (default: false)
    - `:force_normalization`: Always normalize downloads (default: false)

  ## Examples

      iex> YtDlpConfig.get_download_config()
      %{
        format_strategies: %{...},
        base_options: %{...},
        quality_thresholds: %{...},
        ...
      }

      iex> YtDlpConfig.get_download_config(timeout_multiplier: 2.0)
      # All timeouts doubled for slower connections
  """
  @spec get_download_config(keyword()) :: map()
  def get_download_config(opts \\ []) do
    %{
      format_strategies: format_strategies(opts),
      base_options: get_base_options(opts),
      quality_thresholds: quality_thresholds(),
      normalization_config: normalization_config(),
      timeout_config: timeout_config(opts),
      progress_config: progress_config()
      # Note: validation_rules excluded as they contain regex patterns that can't be JSON-encoded
      # Validation is performed in Elixir before sending config to Python
    }
  end

  @doc """
  Returns just the format strategies for debugging/inspection.
  """
  @spec format_strategies(keyword()) :: map()
  def format_strategies(opts \\ []) do
    strategies = %{
      primary: %{
        format: "bv*+ba/b",
        purpose: "Best quality with separate streams (4K/8K capable)",
        description:
          "Downloads highest quality video + audio separately, yt-dlp merges with FFmpeg",
        expected_formats: "~49 formats available, larger downloads for 4K content",
        requires_normalization: true,
        supports_4k: true,
        merge_required: true
      },
      fallback1: %{
        format: "best[ext=mp4]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best",
        purpose: "Compatible MP4 format for maximum compatibility",
        description: "Prioritizes compatibility over absolute best quality, ensures MP4 output",
        expected_formats: "~5-10 formats, smaller file sizes",
        requires_normalization: false,
        supports_4k: false,
        merge_required: false
      },
      fallback2: %{
        format: "worst",
        purpose: "Maximum compatibility for problematic videos",
        description: "Last resort format, guaranteed to work on very old devices",
        expected_formats: "1-3 formats, lowest quality but guaranteed compatibility",
        requires_normalization: false,
        supports_4k: false,
        merge_required: false
      }
    }

    if Keyword.get(opts, :disable_fallbacks, false) do
      Map.take(strategies, [:primary])
    else
      strategies
    end
  end

  @doc """
  Returns quality assessment thresholds.
  """
  @spec quality_thresholds() :: map()
  def quality_thresholds do
    %{
      high: %{
        min_height: 1080,
        description: "≥1080p (4K, 1440p, 1080p)",
        expected_size_mb: 80,
        quality_tier: "high"
      },
      medium: %{
        min_height: 720,
        description: "720p-1079p",
        expected_size_mb: 40,
        quality_tier: "medium"
      },
      low: %{
        min_height: 480,
        description: "480p-719p",
        expected_size_mb: 20,
        quality_tier: "low"
      },
      very_low: %{
        min_height: 0,
        description: "<480p",
        expected_size_mb: 10,
        quality_tier: "very_low"
      }
    }
  end

  @doc """
  Returns normalization configuration.
  """
  @spec normalization_config() :: map()
  def normalization_config do
    %{
      purpose: "Lightweight normalization to fix yt-dlp merge issues",
      when_to_apply: "Only for primary downloads that use separate video/audio streams",
      fallback_behavior: "Proceed with original download if normalization fails",
      # FFmpeg args are provided by FFmpegConfig.get_args(:download_normalization)
      uses_ffmpeg_config: true
    }
  end

  @doc """
  Returns timeout configuration with optional multiplier.
  """
  @spec timeout_config(keyword()) :: map()
  def timeout_config(opts \\ []) do
    multiplier = Keyword.get(opts, :timeout_multiplier, 1.0)

    base_timeouts = %{
      extraction_timeout: 60,
      # 20 minutes for 4K downloads
      download_timeout: 1200,
      # 5 minutes
      socket_timeout: 300,
      # 3 minutes
      fragment_timeout: 180
    }

    # Apply multiplier to all timeouts
    for {key, value} <- base_timeouts, into: %{} do
      {key, round(value * multiplier)}
    end
  end

  @doc """
  Returns validation rules to prevent quality-reducing configurations.
  """
  @spec validation_rules() :: map()
  def validation_rules do
    %{
      forbidden_options: [
        %{
          option: "extractor_args",
          reason: "Reduces available formats from ~49 to ~5, blocking 4K/8K quality"
        },
        %{
          pattern: ~r/\[height<=\d+\]/,
          reason: "Height restrictions block 4K (2160p) and 1440p downloads"
        },
        %{
          pattern: ~r/\[ext=\w+\].*bv\*/,
          reason: "Extension restrictions in primary format may block VP9/AV1 4K streams"
        }
      ],
      required_capabilities: [
        "Must support format selection with fallbacks",
        "Must allow yt-dlp automatic client selection",
        "Must preserve merge capabilities for best quality"
      ]
    }
  end

  @doc """
  Returns progress tracking configuration.
  """
  @spec progress_config() :: map()
  def progress_config do
    %{
      # Log every 10% progress
      log_interval_percent: 10,
      track_download_speed: true,
      track_eta: true,
      track_file_sizes: true,
      structured_logging: true
    }
  end

  ## Private Implementation

  @spec get_base_options(keyword()) :: map()
  defp get_base_options(opts) do
    timeout_config = timeout_config(opts)

    %{
      # Core output settings
      merge_output_format: "mp4",
      restrictfilenames: true,

      # Error handling
      # Fail on error to trigger fallback
      ignoreerrors: false,
      retries: 3,
      fragment_retries: 5,
      skip_unavailable_fragments: true,

      # Timeouts (from timeout_config)
      socket_timeout: timeout_config.socket_timeout,

      # Metadata handling
      # Disabled to avoid potential issues
      embedmetadata: false,
      # Disabled to avoid potential issues
      embedthumbnail: false,

      # Playlist prevention - CRITICAL for single video downloads
      # Only download the first item
      playlist_items: "1",
      # Ensure we get full video info
      extract_flat: false,
      # Don't download playlists
      noplaylist: true,

      # Cache management - CRITICAL to prevent old video downloads
      # Don't use cache directory
      no_cache_dir: true,
      # Disable caching entirely
      cachedir: false,

      # Performance optimizations
      concurrent_fragment_downloads: 5,
      # If available
      external_downloader: "aria2c",

      # FFmpeg postprocessor args for merge operations
      postprocessor_args: %{
        ffmpeg_i: ["-err_detect", "ignore_err", "-fflags", "+genpts"]
      },

      # Certificate handling
      nocheckcertificate: true,

      # CRITICAL: No extractor_args for best quality
      # WARNING: Do not add extractor_args with client restrictions!
      # This reduces available formats from ~49 to ~5, blocking high quality!
      # Let yt-dlp use its optimal default client selection automatically

      # Force normalization if requested
      force_normalization: Keyword.get(opts, :force_normalization, false)
    }
  end

  @doc """
  Validates a yt-dlp configuration against quality requirements.

  Prevents common mistakes that reduce download quality from 4K to 360p.
  """
  @spec validate_config!(map()) :: :ok | no_return()
  def validate_config!(config) do
    # Check for forbidden extractor_args
    if Map.has_key?(config, :extractor_args) do
      raise ArgumentError,
            "extractor_args will reduce available formats from ~49 to ~5, " <>
              "blocking 4K/8K quality. Remove extractor_args to let yt-dlp " <>
              "auto-select optimal clients."
    end

    # Check format strategies for height restrictions
    format_strategies = Map.get(config, :format_strategies, %{})

    for {strategy_name, strategy} <- format_strategies do
      format_str = Map.get(strategy, :format, "")

      if String.contains?(format_str, "[height<=") do
        raise ArgumentError,
              "Height restrictions in #{strategy_name} format will block 4K (2160p) " <>
                "and 1440p downloads. Remove height restrictions from format strings."
      end

      # Check for extension restrictions in primary format
      if strategy_name == :primary and String.contains?(format_str, "[ext=") and
           String.contains?(format_str, "bv*") do
        IO.warn(
          "Extension restrictions in primary format may block VP9/AV1 4K streams. " <>
            "Consider using unrestricted format for maximum quality."
        )
      end
    end

    :ok
  end

  @doc """
  Returns available configuration presets for common scenarios.
  """
  @spec get_preset(atom()) :: keyword()
  def get_preset(preset_name) do
    case preset_name do
      :high_quality ->
        # Default configuration optimized for quality
        []

      :fast_download ->
        [timeout_multiplier: 0.5, disable_fallbacks: true]

      :compatibility_mode ->
        [force_normalization: true]

      :debug_mode ->
        [timeout_multiplier: 3.0]

      _ ->
        raise ArgumentError, "Unknown preset: #{preset_name}"
    end
  end

  @doc """
  Returns configuration suitable for testing without actual downloads.
  """
  @spec get_test_config() :: map()
  def get_test_config do
    config = get_download_config()

    # Modify for testing
    put_in(config, [:base_options, :skip_download], true)
  end
end
