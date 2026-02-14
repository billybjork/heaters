defmodule Heaters.Processing.Encode.MetadataExtraction do
  @moduledoc """
  Video metadata and keyframe extraction for encoding operations.

  Uses existing infrastructure:
  - `Heaters.Processing.Support.FFmpeg.Runner` for metadata extraction
  """

  require Logger
  alias Heaters.Processing.Support.FFmpeg.Runner

  @type metadata_result :: {:ok, map()} | {:error, String.t()}
  @type keyframes_result :: [integer()]

  @doc """
  Extract source video metadata using existing FFmpeg runner.
  """
  @spec extract_source_metadata(String.t(), String.t()) :: metadata_result()
  def extract_source_metadata(source_path, operation_name) do
    Logger.info("#{operation_name}: Extracting source video metadata")

    case Runner.get_video_metadata(source_path) do
      {:ok, metadata} ->
        Logger.info("#{operation_name}: Source metadata: #{inspect(metadata)}")
        {:ok, metadata}

      {:error, reason} ->
        {:error, "Failed to extract source metadata: #{reason}"}
    end
  end

  @doc """
  Extract keyframe offsets from video file using ffprobe.

  Returns a list of byte offsets for keyframes in the video.
  """
  @spec extract_keyframe_offsets(String.t(), String.t()) :: keyframes_result()
  def extract_keyframe_offsets(video_path, operation_name) do
    Logger.debug("#{operation_name}: Extracting keyframe offsets from #{video_path}")

    case run_ffprobe_keyframes(video_path) do
      {:ok, output} ->
        parse_keyframe_output(output, operation_name)

      {:error, exit_code} ->
        Logger.warning("#{operation_name}: ffprobe failed with exit code #{exit_code}")
        []
    end
  rescue
    e ->
      Logger.warning("#{operation_name}: Exception extracting keyframes: #{Exception.message(e)}")

      []
  end

  defp run_ffprobe_keyframes(video_path) do
    case System.cmd("ffprobe", [
           "-v",
           "quiet",
           "-select_streams",
           "v:0",
           "-show_entries",
           "frame=key_frame,pkt_pos",
           "-print_format",
           "json",
           video_path
         ]) do
      {output, 0} -> {:ok, output}
      {_output, exit_code} -> {:error, exit_code}
    end
  end

  defp parse_keyframe_output(output, operation_name) do
    case Jason.decode(output) do
      {:ok, %{"frames" => frames}} ->
        offsets = extract_offsets_from_frames(frames)
        Logger.info("#{operation_name}: Extracted #{length(offsets)} keyframe offsets")
        offsets

      {:error, reason} ->
        Logger.warning("#{operation_name}: Failed to parse keyframe JSON: #{inspect(reason)}")
        []
    end
  end

  defp extract_offsets_from_frames(frames) do
    frames
    |> Enum.filter(fn frame -> Map.get(frame, "key_frame") == 1 end)
    |> Enum.map(&parse_frame_offset/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp parse_frame_offset(frame) do
    case Map.get(frame, "pkt_pos") do
      pos when is_binary(pos) ->
        case Integer.parse(pos) do
          {int_pos, _} -> int_pos
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Check if source video can be reused as proxy based on resolution.

  Returns true if video is 1080p or lower and suitable for proxy use.
  """
  @spec can_reuse_as_proxy?(map()) :: boolean()
  def can_reuse_as_proxy?(%{width: width, height: height})
      when is_integer(width) and is_integer(height) do
    # Reuse if resolution is 1080p or lower (suitable for proxy)
    width <= 1920 and height <= 1080
  end

  def can_reuse_as_proxy?(_metadata), do: false
end
