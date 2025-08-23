defmodule Heaters.Storage.PlaybackCache.TempClip do
  @moduledoc """
  Efficient temporary clip generation using unified FFmpeg stream copy abstraction.

  This module leverages the unified `StreamClip` module for consistent, maintainable 
  clip generation with profile-based configuration and optimal browser compatibility.

  ## Key Features

  - **Unified Architecture**: Uses `StreamClip` for consistent clip generation
  - **Profile-Based**: Uses `:temp_playback` profile for optimal temp clip settings  
  - **Browser Optimized**: Audio removal and fast start for instant playback
  - **Minimal Files**: Typically 2-5MB for quick transfer and playback
  - **Stream Copy**: Zero re-encoding for 10x faster generation

  ## Architecture

  Built on the unified FFmpeg abstraction that provides:
  - Direct CloudFront URL processing (no downloads)
  - Profile-based configuration from `FFmpeg.Config`
  - Consistent error handling and logging

  ## Cleanup

  Cleanup is handled by the scheduled CleanupWorker rather than per-file timers
  for more efficient batch processing.
  """

  require Logger

  alias Heaters.Processing.Support.FFmpeg.StreamClip
  alias Heaters.Repo

  @doc """
  Build a temporary clip file using the unified StreamClip abstraction.

  Uses the `:temp_playback` FFmpeg profile which provides ultra-fast stream copying
  without re-encoding. The resulting file is tiny (2-5MB) and starts playing immediately.

  ## Parameters
  - `clip`: Clip struct with timing and source video information

  ## Returns
  - `{:ok, file_url}` - HTTP URL for direct browser access
  - `{:error, reason}` - FFmpeg error or missing data

  ## Examples

      {:ok, url} = TempClip.build(clip)
      # Returns: {:ok, "/temp/clip_123_456789.mp4?t=123456"}
  """
  @spec build(map()) :: {:ok, String.t()} | {:error, String.t()}
  def build(%{
        id: id,
        start_time_seconds: start_seconds,
        end_time_seconds: end_seconds,
        source_video: source_video
      }) do
    Logger.info("TempClip: Building temp clip #{id} using unified StreamClip abstraction")

    # Use the unified StreamClip module with temp_playback profile
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
  def build(%{id: id} = _clip) do
    Logger.debug("TempClip: Loading source_video for clip #{id}")

    case Repo.get(Heaters.Media.Clip, id) do
      nil ->
        {:error, "Clip not found"}

      clip ->
        loaded_clip = Repo.preload(clip, :source_video)
        build(loaded_clip)
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
