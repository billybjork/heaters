defmodule Heaters.Storage.PlaybackCache.TempClip do
  @moduledoc """
  Efficient temporary clip generation using stream copy from all-I proxy files for instant split-mode compatibility.

  This module leverages the unified `StreamClip` module for consistent, maintainable
  clip generation with profile-based configuration and optimal browser compatibility.

  ## Key Features

  - **Unified Architecture**: Uses `StreamClip` for consistent clip generation
  - **Split-Mode Ready**: Uses stream copy from all-I proxy files for perfect frame-accurate seeking
  - **Instant Generation**: Stream copy provides instant clip creation with zero re-encoding
  - **Browser Optimized**: Fast decode, no audio, +faststart for instant playback
  - **Reasonable Files**: Minimal size overhead since no re-encoding occurs

  ## Architecture

  Built on the unified FFmpeg abstraction that provides:
  - Direct CloudFront URL processing (no downloads)
  - Profile-based configuration from `FFmpeg.Config`
  - DB fps integration for metadata preservation
  - Consistent error handling and logging

  ## Split Mode Benefits

  Unlike regular subclips, these stream-copied clips from all-I proxy sources support reliable seeking:
  - Every frame remains a keyframe from original proxy
  - Browsers can seek to any timestamp without snapping to 0
  - Frame stepping works consistently across all browsers
  - Original timing preserved exactly from source

  ## Cleanup

  Cleanup is handled by the scheduled CleanupWorker rather than per-file timers
  for more efficient batch processing.
  """

  require Logger

  alias Heaters.Processing.Support.FFmpeg.StreamClip
  alias Heaters.Repo

  @doc """
  Build a temporary clip file using stream copy from all-I proxy for split-mode compatibility.

  ## Parameters
  - `clip`: Clip struct with timing and source video information
  - `opts`: Options for temp clip generation (currently unused, for future expansion)

  ## Profile
  Uses `:temp_playback` with stream copy from all-I proxy:
  - Instant generation via stream copy (no re-encoding)
  - Perfect seeking preserved from all-I proxy source
  - No audio for minimal file size
  - +faststart for instant browser playback

  ## Returns
  - `{:ok, file_url}` - HTTP URL for direct browser access
  - `{:error, reason}` - FFmpeg error or missing data

  ## Examples

      {:ok, url} = TempClip.build(clip)
      # Returns: {:ok, "/temp/clip_123_456789.mp4?t=123456"}
      # File supports frame-accurate seeking for split mode
  """
  @spec build(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def build(clip, opts \\ [])

  def build(
        %{
          id: id,
          start_time_seconds: start_seconds,
          end_time_seconds: end_seconds,
          source_video: source_video
        },
        opts
      )
      when is_list(opts) do
    Logger.info("TempClip: Building temp clip #{id} using stream-copy temp_playback profile")

    # Use the unified StreamClip module with temp_playback profile (stream copy)
    StreamClip.generate_clip(
      %{
        id: id,
        start_time_seconds: start_seconds,
        end_time_seconds: end_seconds,
        source_video: source_video
      },
      :temp_playback,
      operation_name: "TempClip",
      cache_buster: true
    )
  end

  # Handle clip without preloaded source_video
  def build(%{id: _id} = clip, opts) when is_list(opts) do
    Logger.debug("TempClip: Loading source_video for clip #{clip.id}")

    case Repo.get(Heaters.Media.Clip, clip.id) do
      nil ->
        {:error, "Clip not found"}

      loaded_clip ->
        loaded_clip = Repo.preload(loaded_clip, :source_video)
        build(loaded_clip, opts)
    end
  end

  @doc """
  Build multiple temporary clips efficiently.

  Processes multiple clips in sequence using the unified abstraction.
  This can be more efficient than individual builds when processing
  clips from the same source video.

  ## Parameters
  - `clips`: List of clip structs

  ## Returns
  - `{:ok, results}` - List of {:ok, url} or {:error, reason} tuples
  - `{:error, reason}` - Fatal error preventing batch processing
  """
  @spec build_batch([map()]) :: {:ok, [map()]} | {:error, String.t()}
  def build_batch(clips) when is_list(clips) do
    Logger.info("TempClip: Building #{length(clips)} temp clips in batch")

    results =
      Enum.map(clips, fn clip ->
        case build(clip) do
          {:ok, url} -> %{clip_id: clip.id, url: url, status: :success}
          {:error, reason} -> %{clip_id: clip.id, error: reason, status: :error}
        end
      end)

    successful = Enum.count(results, fn result -> result.status == :success end)
    failed = length(results) - successful

    Logger.info("TempClip: Batch complete - #{successful} successful, #{failed} failed")

    {:ok, results}
  end

  def build_batch(_), do: {:error, "Invalid clips data - expected list"}
end
