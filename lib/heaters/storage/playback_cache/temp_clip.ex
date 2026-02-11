defmodule Heaters.Storage.PlaybackCache.TempClip do
  @moduledoc """
  Temporary clip generation using FFmpeg stream copy from all-I proxy files.

  Delegates to `StreamClip.generate_clip/3` with the `:temp_playback` profile.
  Stream copy from all-I proxy sources preserves frame-accurate seeking for split mode.
  Cleanup is handled by `PlaybackCache.CleanupWorker`.
  """

  require Logger

  alias Heaters.Processing.Support.FFmpeg.StreamClip
  alias Heaters.Repo

  @doc """
  Build a temporary clip file using the `:temp_playback` stream copy profile.

  Returns `{:ok, "/temp/clip_{id}_{ts}.mp4?t=..."}` or `{:error, reason}`.
  Automatically preloads `source_video` if not already loaded.
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
