defmodule HeatersWeb.KeyframeAnalyzer do
  @moduledoc """
  Utilities for detecting and analyzing keyframe leakage in FFmpeg stream copy operations.

  When using `-c copy` with `-ss`, FFmpeg may include extra frames before the requested
  start time due to keyframe boundaries. This module helps detect clips that may have
  visible pre-roll content.

  ## Usage

      # Check if a clip might have keyframe leakage
      case KeyframeAnalyzer.analyze_clip_timing(clip, source_video) do
        {:ok, :no_leakage} -> 
          # Stream copy is fine
          
        {:potential_leakage, info} ->
          # Consider using precision mode for this clip
          Logger.warning("Potential keyframe leakage detected", info)
      end
  """

  require Logger

  @doc """
  Analyze a clip for potential keyframe leakage issues.

  This function uses heuristics to identify clips that might benefit from 
  precision mode encoding instead of stream copy.

  ## Parameters

  - `clip` - The clip to analyze
  - `source_video` - The source video (needed for video info)

  ## Returns

  - `{:ok, :no_leakage}` - Clip is likely fine with stream copy
  - `{:potential_leakage, info}` - Clip might have visible pre-roll
  - `{:error, reason}` - Analysis failed
  """
  def analyze_clip_timing(clip, source_video) do
    cond do
      # Clips starting at 0 seconds have no pre-roll risk
      clip.start_time_seconds == 0.0 ->
        {:ok, :no_leakage}

      # Very short clips at the beginning are most susceptible 
      clip.start_time_seconds < 2.0 and clip.end_time_seconds - clip.start_time_seconds < 3.0 ->
        {:potential_leakage,
         %{
           reason: :short_clip_near_start,
           start_time: clip.start_time_seconds,
           duration: clip.end_time_seconds - clip.start_time_seconds,
           recommendation: :consider_precision_mode
         }}

      # Clips ending very close to the end might have trailing content
      source_video.duration_seconds &&
          source_video.duration_seconds - clip.end_time_seconds < 1.0 ->
        {:potential_leakage,
         %{
           reason: :clip_near_end,
           end_time: clip.end_time_seconds,
           video_duration: source_video.duration_seconds,
           recommendation: :consider_precision_mode
         }}

      true ->
        {:ok, :no_leakage}
    end
  rescue
    error ->
      Logger.error("Failed to analyze clip timing: #{inspect(error)}")
      {:error, :analysis_failed}
  end

  @doc """
  Get FFmpeg command with precision mode for clips with keyframe leakage.

  This uses re-encoding with ultrafast preset for frame-accurate cutting,
  at the cost of some performance.

  ## Parameters

  - `clip` - The clip to stream
  - `signed_url` - Signed URL for the source video

  ## Returns

  - List of FFmpeg command arguments for precision mode
  """
  def precision_mode_command(clip, signed_url) do
    [
      "ffmpeg",
      "-hide_banner",
      "-loglevel",
      "error",
      # Precise seeking with timestamp handling
      "-ss",
      to_string(clip.start_time_seconds),
      "-to",
      to_string(clip.end_time_seconds),
      "-i",
      signed_url,
      # Re-encode with ultrafast for speed
      "-c:v",
      "libx264",
      "-preset",
      "ultrafast",
      "-crf",
      "23",
      # Audio stream copy (usually safe)
      "-c:a",
      "copy",
      # Timestamp handling for precision
      "-copyts",
      "-avoid_negative_ts",
      "1",
      "-movflags",
      "+faststart",
      "-f",
      "mp4",
      "pipe:1"
    ]
  end

  @doc """
  Check if precision mode should be used for a given clip.

  This combines timing analysis with configuration to decide the encoding mode.

  ## Returns

  - `:stream_copy` - Use fast stream copy mode
  - `:precision` - Use precision re-encoding mode
  """
  def recommend_encoding_mode(clip, source_video) do
    case analyze_clip_timing(clip, source_video) do
      {:ok, :no_leakage} ->
        :stream_copy

      {:potential_leakage, _info} ->
        # For now, we log but still use stream copy
        # In the future, this could be configurable per-clip
        Logger.info("Keyframe leakage detected for clip #{clip.id}, but using stream copy",
          clip_id: clip.id,
          start_time: clip.start_time_seconds
        )

        :stream_copy

      {:error, _reason} ->
        # Default to stream copy on analysis failure
        :stream_copy
    end
  end
end
