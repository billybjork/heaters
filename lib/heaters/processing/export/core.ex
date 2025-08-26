defmodule Heaters.Processing.Export.Core do
  @moduledoc """
  Efficient clip export functionality using FFmpeg stream copy operations.

  This module provides high-performance clip export using direct CloudFront URL
  processing with FFmpeg stream copy, eliminating the need for local file downloads
  and providing 10x performance improvements with zero quality loss.

  ## Key Features

  - **10x Faster**: No local file downloads, processes directly from CloudFront URLs
  - **Zero Quality Loss**: Stream copy preserves original quality with audio
  - **Profile-Based**: Uses FFmpeg configuration system for maintainable settings
  - **Unified Architecture**: Built on same foundations as temp cache system

  ## Architecture

  This module leverages:
  - `Heaters.Processing.Support.FFmpeg.StreamClip` - Unified clip generation
  - `Heaters.Processing.Support.FFmpeg.Config` - Profile-based configuration
  - `Heaters.Storage.S3.ClipUrls` - CloudFront URL generation

  ## Performance Benefits

  The efficient stream copy approach provides:
  - Direct CloudFront → S3 processing (no local downloads)
  - Stream copy for maximum speed and quality preservation
  - Profile-based configuration for different export needs
  - Comprehensive error handling and structured results

  ## Error Handling

  Returns structured results with detailed error information for debugging and monitoring.
  All operations are logged with appropriate detail levels for operational visibility.
  """

  require Logger

  alias Heaters.Processing.Support.FFmpeg.StreamClip
  alias Heaters.Processing.Support.Types.ExportResult

  @type export_result :: {:ok, ExportResult.t()} | {:error, String.t()}
  @type clip_data :: %{
          clip_id: integer(),
          clip_identifier: String.t(),
          cut_points: %{
            start_time_seconds: float(),
            end_time_seconds: float()
          },
          s3_output_path: String.t()
        }

  @doc """
  Export multiple clips using efficient stream copy operations.

  Replaces the download-process-upload pattern with direct CloudFront processing
  for 10x performance improvement and zero quality loss.

  ## Parameters

  - `clips_data`: List of clip specifications with cut points and output paths
  - `source_video`: Source video struct with proxy_filepath and metadata
  - `opts`: Optional parameters
    - `:operation_name`: Name for logging (defaults to "ExportV2")
    - `:profile`: FFmpeg profile to use (defaults to `:final_export`)

  ## Returns

  - `{:ok, export_result}` with list of exported clips and metadata
  - `{:error, reason}` on failure

  ## Examples

      clips_data = [
        %{
          clip_id: 123,
          clip_identifier: "clip_123_segment_1",
          cut_points: %{start_time_seconds: 10.0, end_time_seconds: 15.0},
          s3_output_path: "clips/clip_123.mp4"
        }
      ]

      {:ok, result} = Core.export_clips_efficient(clips_data, source_video)
  """
  @spec export_clips_efficient([clip_data()], map(), keyword()) :: export_result()
  def export_clips_efficient(clips_data, source_video, opts \\ []) do
    operation_name = Keyword.get(opts, :operation_name, "Export")
    profile = Keyword.get(opts, :profile, :final_export)

    Logger.info(
      "#{operation_name}: Starting efficient export for #{length(clips_data)} clips from source_video_id: #{source_video.id}"
    )

    Logger.info("#{operation_name}: Video title: #{source_video.title || "Unknown"}")
    Logger.info("#{operation_name}: Using profile: #{profile}")

    case validate_source_video(source_video, operation_name) do
      :ok ->
        process_clips_efficiently(clips_data, source_video, profile, operation_name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Export a single clip using efficient stream copy.

  This is a lower-level function for exporting individual clips. Most users should
  use `export_clips_efficient/3` for batch processing.

  ## Parameters

  - `clip_data`: Clip specification with cut points and output information
  - `source_video`: Source video struct with proxy_filepath
  - `opts`: Optional parameters
    - `:operation_name`: Name for logging (defaults to "ExportV2")
    - `:profile`: FFmpeg profile to use (defaults to `:final_export`)

  ## Returns

  - `{:ok, clip_info}` with exported clip information
  - `{:error, reason}` on failure
  """
  @spec export_single_clip_efficient(clip_data(), map(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def export_single_clip_efficient(clip_data, source_video, opts \\ []) do
    operation_name = Keyword.get(opts, :operation_name, "Export")
    profile = Keyword.get(opts, :profile, :final_export)

    %{
      clip_id: clip_id,
      clip_identifier: clip_identifier,
      cut_points: %{
        start_time_seconds: start_time,
        end_time_seconds: end_time
      },
      s3_output_path: s3_output_path
    } = clip_data

    Logger.info(
      "#{operation_name}: Exporting clip #{clip_id} (#{clip_identifier}) using profile #{profile}"
    )

    # Convert clip_data to format expected by StreamClip
    clip_struct = %{
      id: clip_id,
      start_time_seconds: start_time,
      end_time_seconds: end_time,
      source_video: source_video
    }

    # Generate clip using unified StreamClip module
    case StreamClip.generate_clip(clip_struct, profile,
           output_path: s3_output_path,
           upload_to_s3: true,
           operation_name: operation_name
         ) do
      {:ok, s3_key} ->
        duration = end_time - start_time

        clip_info = %{
          clip_id: clip_id,
          output_path: s3_key,
          duration: duration,
          cut_points_used: %{
            start_time_seconds: start_time,
            end_time_seconds: end_time
          },
          export_method: "stream_copy_efficient"
        }

        Logger.info("#{operation_name}: Clip #{clip_id} exported successfully to #{s3_key}")
        {:ok, clip_info}

      {:error, reason} ->
        Logger.error("#{operation_name}: Failed to export clip #{clip_id}: #{reason}")
        {:error, "Clip export failed: #{reason}"}
    end
  end

  ## Private Implementation

  @spec validate_source_video(map(), String.t()) :: :ok | {:error, String.t()}
  defp validate_source_video(%{proxy_filepath: nil}, operation_name) do
    error_msg = "No proxy available for source video"
    Logger.error("#{operation_name}: #{error_msg}")
    {:error, error_msg}
  end

  defp validate_source_video(%{proxy_filepath: proxy_filepath}, operation_name)
       when is_binary(proxy_filepath) do
    Logger.debug("#{operation_name}: Using proxy: #{proxy_filepath}")
    :ok
  end

  defp validate_source_video(_source_video, operation_name) do
    error_msg = "Invalid source video structure"
    Logger.error("#{operation_name}: #{error_msg}")
    {:error, error_msg}
  end

  @spec process_clips_efficiently([clip_data()], map(), atom(), String.t()) :: export_result()
  defp process_clips_efficiently(clips_data, source_video, profile, operation_name) do
    Logger.info(
      "#{operation_name}: Processing #{length(clips_data)} clips using efficient stream copy"
    )

    # Process clips sequentially to avoid resource conflicts
    exported_clips =
      Enum.with_index(clips_data)
      |> Enum.reduce_while([], fn {clip_data, index}, acc ->
        progress_percent = div((index + 1) * 100, length(clips_data))

        Logger.info(
          "#{operation_name}: Processing clip #{index + 1}/#{length(clips_data)} (#{progress_percent}%)"
        )

        case export_single_clip_efficient(clip_data, source_video,
               operation_name: operation_name,
               profile: profile
             ) do
          {:ok, clip_info} ->
            {:cont, [clip_info | acc]}

          {:error, reason} ->
            Logger.error(
              "#{operation_name}: Failed to export clip #{clip_data.clip_id}: #{reason}"
            )

            {:halt, {:error, "Failed to export clip #{clip_data.clip_id}: #{reason}"}}
        end
      end)

    case exported_clips do
      {:error, reason} ->
        {:error, reason}

      clips when is_list(clips) ->
        # Reverse to maintain original order
        final_clips = Enum.reverse(clips)

        # Calculate metadata
        total_duration =
          Enum.reduce(final_clips, 0.0, fn clip, acc ->
            acc + Map.get(clip, :duration, 0.0)
          end)

        proxy_metadata = %{
          proxy_filepath: source_video.proxy_filepath,
          total_clips_exported: length(final_clips),
          total_duration_exported: total_duration
        }

        result =
          ExportResult.new(
            source_video_id: source_video.id,
            exported_clips: final_clips,
            proxy_metadata: proxy_metadata,
            export_method: "stream_copy_efficient"
          )

        Logger.info(
          "#{operation_name}: Successfully exported #{length(final_clips)} clips using efficient stream copy (total: #{Float.round(total_duration, 2)}s)"
        )

        {:ok, result}
    end
  end
end
