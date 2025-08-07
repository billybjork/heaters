defmodule Heaters.Processing.Export.Core do
  @moduledoc """
  Native Elixir implementation of clip export functionality.

  Replaces the Python export_clips.py task with native Elixir/FFmpex implementation,
  providing the same functionality with better integration, error handling, and performance.

  This module handles:
  - Single clip export using FFmpeg stream copy
  - Batch clip export processing
  - Progress reporting and logging
  - S3 integration for downloads and uploads
  - Metadata extraction and validation

  Uses existing infrastructure:
  - `Heaters.Processing.Support.FFmpeg.Runner` for video operations
  - `Heaters.Storage.S3.Core` for S3 operations
  - `Heaters.Processing.Support.Types` for structured results
  """

  require Logger
  import FFmpex
  use FFmpex.Options

  alias Heaters.Processing.Support.FFmpeg.Runner
  alias Heaters.Processing.Support.Types.ExportResult
  alias Heaters.Storage.S3.Core, as: S3Core

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
  Export multiple clips from a proxy file using stream copy operations.

  Replaces the Python `run_export_clips` function with native Elixir implementation.

  ## Parameters
  - `proxy_path`: S3 path to the source proxy file
  - `clips_data`: List of clip specifications with cut points and output paths
  - `source_video_id`: Database ID of the source video (for logging)
  - `video_title`: Video title for logging and debugging
  - `opts`: Optional parameters
    - `:operation_name`: Name for logging (defaults to "ExportClips")
    - `:temp_dir`: Custom temporary directory (defaults to system temp)

  ## Returns
  - `{:ok, export_result}` with list of exported clips and metadata
  - `{:error, reason}` on failure

  ## Examples

      clips_data = [
        %{
          clip_id: 123,
          clip_identifier: "clip_123_segment_1", 
          cut_points: %{start_time_seconds: 10.0, end_time_seconds: 15.0},
          s3_output_path: "final_clips/clip_123.mp4"
        }
      ]
      
      {:ok, result} = ExportCore.export_clips_from_proxy(
        "review_proxies/video_456_proxy.mp4",
        clips_data,
        456,
        "My Video Title"
      )
  """
  @spec export_clips_from_proxy(String.t(), [clip_data()], integer(), String.t(), keyword()) ::
          export_result()
  def export_clips_from_proxy(proxy_path, clips_data, source_video_id, video_title, opts \\ []) do
    operation_name = Keyword.get(opts, :operation_name, "ExportClips")
    temp_dir = Keyword.get(opts, :temp_dir)

    Logger.info(
      "#{operation_name}: Starting export for #{length(clips_data)} clips from source_video_id: #{source_video_id}"
    )

    Logger.info("#{operation_name}: Video title: #{video_title}")
    Logger.info("#{operation_name}: Proxy path: #{proxy_path}")

    with {:ok, work_dir} <- setup_temp_directory(temp_dir, operation_name),
         {:ok, local_proxy_path} <- download_proxy_file(proxy_path, work_dir, operation_name),
         {:ok, proxy_metadata} <- extract_proxy_metadata(local_proxy_path, operation_name),
         {:ok, exported_clips} <-
           export_all_clips(local_proxy_path, clips_data, proxy_metadata, operation_name) do
      result =
        ExportResult.new(
          source_video_id: source_video_id,
          exported_clips: exported_clips,
          proxy_metadata: proxy_metadata,
          export_method: "stream_copy_native_elixir"
        )

      Logger.info(
        "#{operation_name}: Successfully exported #{length(exported_clips)} clips using native Elixir"
      )

      {:ok, result}
    else
      {:error, reason} ->
        Logger.error(
          "#{operation_name}: Export failed for source_video_id #{source_video_id}: #{reason}"
        )

        {:error, reason}
    end
  end

  @doc """
  Export a single clip segment using FFmpeg stream copy.

  This is a lower-level function for exporting individual clips. Most users should
  use `export_clips_from_proxy/5` for batch processing.

  ## Parameters
  - `source_video_path`: Local path to source video file
  - `clip_data`: Clip specification with cut points and output information
  - `output_dir`: Directory to save the exported clip
  - `opts`: Optional parameters
    - `:operation_name`: Name for logging (defaults to "ExportClip")

  ## Returns
  - `{:ok, clip_info}` with exported clip information
  - `{:error, reason}` on failure
  """
  @spec export_single_clip(String.t(), clip_data(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def export_single_clip(source_video_path, clip_data, output_dir, opts \\ []) do
    operation_name = Keyword.get(opts, :operation_name, "ExportClip")

    %{
      clip_id: clip_id,
      clip_identifier: clip_identifier,
      cut_points: %{
        start_time_seconds: start_time,
        end_time_seconds: end_time
      },
      s3_output_path: s3_output_path
    } = clip_data

    Logger.info("#{operation_name}: Exporting clip #{clip_id} (#{clip_identifier})")

    duration = end_time - start_time
    local_output_path = Path.join(output_dir, "#{clip_identifier}.mp4")

    Logger.debug(
      "#{operation_name}: Clip #{clip_id} - start: #{start_time}s, end: #{end_time}s, duration: #{duration}s"
    )

    # Use FFmpex to create the clip with stream copy for maximum performance
    try do
      command =
        FFmpex.new_command()
        |> add_input_file(source_video_path)
        |> add_file_option(option_ss(Float.to_string(start_time)))
        |> add_output_file(local_output_path)
        |> add_file_option(option_t(Float.to_string(duration)))
        |> add_file_option(option_map("0"))
        |> add_file_option(option_c("copy"))
        |> add_file_option(option_avoid_negative_ts("make_zero"))
        |> add_global_option(option_y())

      Logger.debug("#{operation_name}: Executing FFmpeg stream copy for clip #{clip_id}")

      case FFmpex.execute(command) do
        {:ok, _output} ->
          case File.stat(local_output_path) do
            {:ok, %File.Stat{size: file_size}} when file_size > 0 ->
              Logger.info(
                "#{operation_name}: Clip #{clip_id} exported successfully: #{file_size} bytes"
              )

              # Upload to S3
              case upload_clip_to_s3(local_output_path, s3_output_path, operation_name) do
                {:ok, _} ->
                  # Get actual duration from exported file for verification
                  actual_duration = get_clip_duration(local_output_path)

                  clip_info = %{
                    clip_id: clip_id,
                    output_path: s3_output_path,
                    duration: actual_duration,
                    file_size_bytes: file_size,
                    cut_points_used: %{
                      start_time_seconds: start_time,
                      end_time_seconds: end_time
                    }
                  }

                  {:ok, clip_info}

                {:error, upload_reason} ->
                  {:error, "Failed to upload clip #{clip_id} to S3: #{upload_reason}"}
              end

            {:ok, %File.Stat{size: 0}} ->
              {:error, "Exported clip #{clip_id} file is empty: #{local_output_path}"}

            {:error, stat_reason} ->
              {:error, "Exported clip #{clip_id} file not created: #{inspect(stat_reason)}"}
          end

        {:error, ffmpeg_reason} ->
          Logger.error(
            "#{operation_name}: FFmpeg failed to export clip #{clip_id}: #{inspect(ffmpeg_reason)}"
          )

          {:error, "FFmpeg clip export failed: #{inspect(ffmpeg_reason)}"}
      end
    rescue
      e ->
        Logger.error(
          "#{operation_name}: Exception exporting clip #{clip_id}: #{Exception.message(e)}"
        )

        {:error, "Exception exporting clip: #{Exception.message(e)}"}
    end
  end

  ## Private helper functions

  # Set up temporary working directory
  @spec setup_temp_directory(String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp setup_temp_directory(nil, operation_name) do
    case System.tmp_dir() do
      nil ->
        {:error, "#{operation_name}: Unable to determine system temporary directory"}

      temp_dir ->
        work_dir = Path.join(temp_dir, "heaters_export_#{:os.system_time(:millisecond)}")

        case File.mkdir_p(work_dir) do
          :ok ->
            {:ok, work_dir}

          {:error, reason} ->
            {:error, "#{operation_name}: Failed to create temp directory: #{inspect(reason)}"}
        end
    end
  end

  defp setup_temp_directory(custom_temp_dir, operation_name) do
    work_dir = Path.join(custom_temp_dir, "heaters_export_#{:os.system_time(:millisecond)}")

    case File.mkdir_p(work_dir) do
      :ok ->
        {:ok, work_dir}

      {:error, reason} ->
        {:error, "#{operation_name}: Failed to create custom temp directory: #{inspect(reason)}"}
    end
  end

  # Download proxy file from S3 to local temporary directory
  @spec download_proxy_file(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp download_proxy_file(proxy_s3_path, work_dir, operation_name) do
    local_proxy_path = Path.join(work_dir, "proxy.mp4")

    Logger.info("#{operation_name}: Downloading proxy file from S3: #{proxy_s3_path}")

    case S3Core.download_file(proxy_s3_path, local_proxy_path, operation_name: operation_name) do
      {:ok, ^local_proxy_path} ->
        Logger.debug("#{operation_name}: Proxy file downloaded successfully")
        {:ok, local_proxy_path}

      {:error, reason} ->
        {:error, "Failed to download proxy file: #{reason}"}
    end
  end

  # Extract video metadata from proxy file
  @spec extract_proxy_metadata(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  defp extract_proxy_metadata(local_proxy_path, operation_name) do
    Logger.debug("#{operation_name}: Extracting proxy metadata")

    case Runner.get_video_metadata(local_proxy_path) do
      {:ok, metadata} ->
        Logger.info("#{operation_name}: Proxy metadata: #{inspect(metadata)}")
        {:ok, metadata}

      {:error, reason} ->
        Logger.warning("#{operation_name}: Failed to extract proxy metadata: #{reason}")
        # Return basic metadata structure to prevent pipeline failure
        {:ok, %{duration: 0.0, fps: 30.0, width: 1920, height: 1080}}
    end
  end

  # Export all clips in the list
  @spec export_all_clips(String.t(), [clip_data()], map(), String.t()) ::
          {:ok, [map()]} | {:error, String.t()}
  defp export_all_clips(local_proxy_path, clips_data, _proxy_metadata, operation_name) do
    work_dir = Path.dirname(local_proxy_path)

    Logger.info("#{operation_name}: Processing #{length(clips_data)} clips for export")

    # Process clips sequentially to avoid resource conflicts
    exported_clips =
      Enum.with_index(clips_data)
      |> Enum.reduce_while([], fn {clip_data, index}, acc ->
        progress_percent = div((index + 1) * 100, length(clips_data))

        Logger.info(
          "#{operation_name}: Processing clip #{index + 1}/#{length(clips_data)} (#{progress_percent}%)"
        )

        case export_single_clip(local_proxy_path, clip_data, work_dir,
               operation_name: operation_name
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
        Logger.info("#{operation_name}: Successfully exported #{length(final_clips)} clips")
        {:ok, final_clips}
    end
  end

  # Upload exported clip to S3
  @spec upload_clip_to_s3(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp upload_clip_to_s3(local_path, s3_output_path, operation_name) do
    Logger.debug("#{operation_name}: Uploading clip to S3: #{s3_output_path}")

    case S3Core.upload_file(local_path, s3_output_path, operation_name: operation_name) do
      {:ok, s3_key} ->
        Logger.debug("#{operation_name}: Clip uploaded successfully to #{s3_key}")
        {:ok, s3_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Get duration of exported clip file for verification
  @spec get_clip_duration(String.t()) :: float()
  defp get_clip_duration(video_path) do
    case Runner.get_video_metadata(video_path) do
      {:ok, %{duration: duration}} when is_number(duration) ->
        duration

      _ ->
        Logger.warning(
          "ExportCore: Could not determine clip duration for #{video_path}, defaulting to 0.0"
        )

        0.0
    end
  end
end
