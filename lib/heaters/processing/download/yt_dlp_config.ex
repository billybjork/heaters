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

  ## Usage

      config = YtDlpConfig.get_download_config()
      # Returns complete configuration map with all strategies and options

  ## Critical Quality Requirements

  This configuration implements 4K/8K quality downloads. To maintain this capability:

  NEVER ADD height restrictions to format strings (e.g., [height<=1080])
  NEVER ADD client restrictions via extractor_args
  NEVER ADD quality caps or manual limitations
  NEVER ADD extension restrictions to primary format (blocks VP9/AV1 4K)

  ALWAYS use unrestricted format strings
  ALWAYS let yt-dlp choose optimal clients automatically
  ALWAYS test with expected ~49 formats and 80MB+ downloads
  ALWAYS use three-tier fallback strategy

  Breaking these rules reduces quality from 4K to 360p (verified multiple times).
  """

  @doc """
  Returns complete yt-dlp download configuration.

  ## Parameters
  - `opts`: Optional parameters for configuration customization
    - `:timeout_multiplier`: Multiply all timeouts by this factor (default: 1.0)
    - `:disable_fallbacks`: Only use primary format (default: false)

  ## Examples

      iex> YtDlpConfig.get_download_config()
      %{
        format_strategies: %{...},
        base_options: %{...},
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
      timeout_config: timeout_config(opts)
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
        description:
          "Downloads highest quality video + audio separately, yt-dlp merges with FFmpeg",
        requires_normalization: true
      },
      fallback1: %{
        format: "best[ext=mp4]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best",
        description: "Prioritizes compatibility over absolute best quality, ensures MP4 output",
        requires_normalization: false
      },
      fallback2: %{
        format: "worst",
        description: "Last resort format, guaranteed to work on very old devices",
        requires_normalization: false
      }
    }

    if Keyword.get(opts, :disable_fallbacks, false) do
      Map.take(strategies, [:primary])
    else
      strategies
    end
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
  Validates a yt-dlp configuration against quality requirements.

  Prevents common mistakes that reduce download quality from 4K to 360p.
  """
  @spec validate_config!(map()) :: :ok | no_return()
  def validate_config!(config) when is_map(config) do
    if Map.has_key?(config, :extractor_args) do
      raise ArgumentError,
            "extractor_args will reduce available formats from ~49 to ~5, " <>
              "blocking 4K/8K quality. Remove extractor_args to let yt-dlp " <>
              "auto-select optimal clients."
    end

    format_strategies = Map.get(config, :format_strategies, %{})

    for {strategy_name, strategy} <- format_strategies do
      format_str = Map.get(strategy, :format, "")

      if String.contains?(format_str, "[height<=") do
        raise ArgumentError,
              "Height restrictions in #{strategy_name} format will block 4K (2160p) " <>
                "and 1440p downloads. Remove height restrictions from format strings."
      end

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
      nocheckcertificate: true

      # CRITICAL: No extractor_args for best quality
      # WARNING: Do not add extractor_args with client restrictions!
      # This reduces available formats from ~49 to ~5, blocking high quality!
      # Let yt-dlp use its optimal default client selection automatically
    }
  end
end
