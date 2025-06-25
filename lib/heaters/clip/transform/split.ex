defmodule Heaters.Clip.Transform.Split do
  @moduledoc """
  Video splitting operations using FFmpeg via ffmpex.

  This module replicates the functionality from split.py, handling:
  - Downloading source videos from S3
  - Splitting videos at specific frames using ffmpeg
  - Uploading split clips to S3
  - Cleaning up original source files
  - Managing clip state transitions
  """

  import FFmpex
  use FFmpex.Options

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Infrastructure.S3
  alias Heaters.Utils
  require Logger

  # Configuration constants matching split.py
  @min_clip_duration_seconds 0.5

  # FFmpeg encoding options matching the Python implementation
  # These are hardcoded in the create_video_clip function to match the Python script exactly

  @type split_params :: %{
    split_at_frame: integer(),
    original_start_time: float(),
    original_end_time: float(),
    original_start_frame: integer(),
    original_end_frame: integer(),
    source_title: String.t(),
    fps: float() | nil,
    source_video_id: integer()
  }

  @type split_result :: %{
    status: String.t(),
    original_clip_id: integer(),
    created_clips: list(map()),
    cleanup: map(),
    metadata: map()
  }

  @doc """
  Main entry point for splitting a clip at a specific frame.

  This function orchestrates the entire split process:
  1. Downloads the source video from S3
  2. Splits it at the specified frame using ffmpeg
  3. Uploads the new clips to S3
  4. Cleans up the original file
  5. Updates database state

  Args:
    clip_id: The ID of the clip to split
    split_at_frame: The frame number where to split the video

  Returns:
    {:ok, result} on success with created clip data
    {:error, reason} on failure
  """
  @spec run_split(integer(), integer()) :: {:ok, split_result()} | {:error, any()}
  def run_split(clip_id, split_at_frame) do
    Logger.info("Split: Starting split for clip_id: #{clip_id} at frame: #{split_at_frame}")

    # Create the temp directory before the try block
    with {:ok, temp_dir} <- create_temp_directory() do
      try do
        # The main processing chain runs inside the try block
        with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
             {:ok, split_params} <- build_split_params(clip, split_at_frame),
             {:ok, local_video_path} <- download_source_video(clip, temp_dir),
             {:ok, created_clips} <- split_video_file(local_video_path, temp_dir, split_params),
             {:ok, uploaded_clips} <- upload_split_clips(created_clips, clip),
             {:ok, cleanup_result} <- cleanup_original_file(clip),
             {:ok, new_clip_records} <- create_clip_records(uploaded_clips, clip),
             :ok <- update_original_clip_state(clip_id) do

          result = %{
            status: "success",
            original_clip_id: clip_id,
            created_clips: uploaded_clips,
            cleanup: cleanup_result,
            metadata: %{
              split_at_frame: split_at_frame,
              clips_created: length(new_clip_records),
              total_duration: Enum.reduce(uploaded_clips, 0.0, & &1.duration_seconds + &2),
              new_clip_ids: Enum.map(new_clip_records, & &1.id)
            }
          }

          Logger.info("Split: Successfully completed split for clip_id: #{clip_id}")
          {:ok, result}
        else
          error ->
            Logger.error("Split: Failed to split clip_id: #{clip_id}, error: #{inspect(error)}")
            error
        end
      after
        # This after block will run whether the try block succeeds or fails
        Logger.info("Split: Cleaning up temp directory: #{temp_dir}")
        File.rm_rf(temp_dir)
      end
    else
      # This handles the failure of create_temp_directory itself
      error ->
        Logger.error("Split: Could not create temp directory: #{inspect(error)}")
        error
    end
  end

  # Private functions implementing the core split logic

  @spec build_split_params(Clip.t(), integer()) :: {:ok, split_params()} | {:error, any()}
  defp build_split_params(%Clip{} = clip, split_at_frame) do
    if is_nil(clip.source_video) do
      {:error, "Clip has no associated source video"}
    else
      fps = get_video_fps(clip) || 30.0

      split_params = %{
        split_at_frame: split_at_frame,
        original_start_time: clip.start_time_seconds,
        original_end_time: clip.end_time_seconds,
        original_start_frame: clip.start_frame,
        original_end_frame: clip.end_frame,
        source_title: clip.source_video.title || "source_#{clip.source_video_id}",
        fps: fps,
        source_video_id: clip.source_video_id
      }

      # Validate split frame is within bounds
      if split_at_frame > clip.start_frame and split_at_frame < clip.end_frame do
        {:ok, split_params}
      else
        {:error, "Split frame #{split_at_frame} is outside clip range (#{clip.start_frame}-#{clip.end_frame})"}
      end
    end
  end

  @spec get_video_fps(Clip.t()) :: float() | nil
  defp get_video_fps(%Clip{processing_metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "fps") || Map.get(metadata, :fps)
  end
  defp get_video_fps(_clip), do: nil

  @spec create_temp_directory() :: {:ok, String.t()} | {:error, any()}
  defp create_temp_directory do
    case System.tmp_dir() do
      nil -> {:error, "Could not access system temp directory"}
      temp_root ->
        temp_dir = Path.join(temp_root, "heaters_split_#{System.unique_integer([:positive])}")
        case File.mkdir_p(temp_dir) do
          :ok -> {:ok, temp_dir}
          {:error, reason} -> {:error, "Failed to create temp directory: #{reason}"}
        end
    end
  end

  @spec download_source_video(Clip.t(), String.t()) :: {:ok, String.t()} | {:error, any()}
  defp download_source_video(%Clip{clip_filepath: s3_path} = _clip, temp_dir) do
    local_filename = Path.basename(s3_path)
    local_path = Path.join(temp_dir, local_filename)

    Logger.info("Split: Downloading #{s3_path} to #{local_path}")

    bucket_name = get_s3_bucket_name()
    s3_key = String.trim_leading(s3_path, "/")

    try do
      # Use streaming download for better memory efficiency with large files
      file = File.open!(local_path, [:write, :binary])

      try do
        ExAws.S3.get_object(bucket_name, s3_key)
        |> ExAws.stream!()
        |> Enum.each(&IO.binwrite(file, &1))
      after
        File.close(file)
      end

      if File.exists?(local_path) do
        {:ok, local_path}
      else
        {:error, "Downloaded file does not exist at #{local_path}"}
      end
    rescue
      error ->
        Logger.error("Split: Failed to stream download from S3: #{Exception.message(error)}")
        {:error, "Failed to download from S3: #{Exception.message(error)}"}
    end
  end

  @spec get_s3_bucket_name() :: String.t()
  defp get_s3_bucket_name do
    case Application.get_env(:heaters, :s3_bucket) do
      nil ->
        raise "S3 bucket name not configured. Please set :s3_bucket in application config."
      bucket_name ->
        bucket_name
    end
  end

  @spec split_video_file(String.t(), String.t(), split_params()) :: {:ok, list(map())} | {:error, any()}
  defp split_video_file(source_video_path, output_dir, split_params) do
    %{
      split_at_frame: split_at_frame,
      original_start_time: original_start_time,
      original_end_time: original_end_time,
      original_start_frame: original_start_frame,
      original_end_frame: original_end_frame,
      source_title: source_title,
      fps: fps
    } = split_params

    # Get FPS from video file if not provided in params
    fps = if fps && fps > 0 do
      fps
    else
      {:ok, detected_fps} = get_video_fps_with_ffprobe(source_video_path)
      detected_fps
    end

    Logger.info("Split: Splitting video at frame #{split_at_frame} (FPS: #{Float.round(fps, 3)})")

    # Calculate split time
    split_time_abs = split_at_frame / fps

    sanitized_source_title = Utils.sanitize_filename(source_title)

    # Create clip A (before split)
    start_a_time = original_start_time
    end_a_time = split_time_abs
    duration_a = end_a_time - start_a_time

    created_clips = if duration_a >= @min_clip_duration_seconds do
      start_f_a = original_start_frame
      end_f_a = split_at_frame - 1
      id_a = "#{sanitized_source_title}_#{start_f_a}_#{end_f_a}"
      filename_a = "#{id_a}.mp4"
      output_path_a = Path.join(output_dir, filename_a)

      case create_video_clip(source_video_path, output_path_a, start_a_time, end_a_time) do
        {:ok, file_size_a} ->
          clip_a = %{
            clip_identifier: id_a,
            filename: filename_a,
            local_path: output_path_a,
            start_time_seconds: start_a_time,
            end_time_seconds: end_a_time,
            start_frame: start_f_a,
            end_frame: end_f_a,
            duration_seconds: duration_a,
            file_size: file_size_a
          }
          Logger.info("Split: Created clip A: #{filename_a} (#{Float.round(duration_a, 2)}s)")
          [clip_a]
        {:error, reason} ->
          Logger.error("Split: Failed to create clip A: #{reason}")
          []
      end
    else
      Logger.info("Split: Skipping clip A - too short (#{duration_a}s)")
      []
    end

    # Create clip B (after split)
    start_b_time = split_time_abs
    end_b_time = original_end_time
    duration_b = end_b_time - start_b_time

    created_clips = if duration_b >= @min_clip_duration_seconds do
      start_f_b = split_at_frame
      end_f_b = original_end_frame
      id_b = "#{sanitized_source_title}_#{start_f_b}_#{end_f_b}"
      filename_b = "#{id_b}.mp4"
      output_path_b = Path.join(output_dir, filename_b)

      case create_video_clip(source_video_path, output_path_b, start_b_time, end_b_time) do
        {:ok, file_size_b} ->
          clip_b = %{
            clip_identifier: id_b,
            filename: filename_b,
            local_path: output_path_b,
            start_time_seconds: start_b_time,
            end_time_seconds: end_b_time,
            start_frame: start_f_b,
            end_frame: end_f_b,
            duration_seconds: duration_b,
            file_size: file_size_b
          }
          Logger.info("Split: Created clip B: #{filename_b} (#{Float.round(duration_b, 2)}s)")
          created_clips ++ [clip_b]
        {:error, reason} ->
          Logger.error("Split: Failed to create clip B: #{reason}")
          created_clips
      end
    else
      Logger.info("Split: Skipping clip B - too short (#{duration_b}s)")
      created_clips
    end

    if Enum.empty?(created_clips) do
      {:error, "Split operation did not create any valid clips"}
    else
      {:ok, created_clips}
    end
  end

  @spec get_video_fps_with_ffprobe(String.t()) :: {:ok, float()} | {:error, any()}
  defp get_video_fps_with_ffprobe(video_path) do
    try do
      # Use System.cmd to call ffprobe directly since FFmpex doesn't expose ffprobe options
      # Replicating: ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 video_path
      {output, exit_code} = System.cmd("ffprobe", [
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=r_frame_rate",
        "-of", "default=noprint_wrappers=1:nokey=1",
        video_path
      ])

      if exit_code == 0 do
        fps_string = String.trim(output)
        case String.split(fps_string, "/") do
          [num_str, den_str] ->
            with {num, ""} <- Integer.parse(num_str),
                 {den, ""} <- Integer.parse(den_str),
                 true <- den > 0 do
              fps = num / den
              Logger.info("Split: Detected video FPS: #{Float.round(fps, 3)}")
              {:ok, fps}
            else
              _ ->
                Logger.warning("Split: Could not parse FPS from '#{fps_string}', defaulting to 30.0")
                {:ok, 30.0}
            end
          _ ->
            Logger.warning("Split: Could not parse FPS from '#{fps_string}', defaulting to 30.0")
            {:ok, 30.0}
        end
      else
        Logger.warning("Split: FFprobe command failed with exit code #{exit_code}, defaulting to 30.0")
        {:ok, 30.0}
      end
    rescue
      e ->
        Logger.warning("Split: Exception getting FPS: #{inspect(e)}, defaulting to 30.0")
        {:ok, 30.0}
    end
  end

  @spec create_video_clip(String.t(), String.t(), float(), float()) :: {:ok, integer()} | {:error, any()}
  defp create_video_clip(input_path, output_path, start_time, end_time) do
    try do
      # Create FFmpeg command matching the Python implementation exactly:
      # ffmpeg -i input -ss start_time -to end_time
      # -map 0:v:0? -map 0:a:0?
      # -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p
      # -c:a aac -b:a 128k
      # -movflags +faststart -y output
      command =
        FFmpex.new_command()
        |> add_input_file(input_path)
        |> add_file_option(option_ss(start_time))
        |> add_file_option(option_to(end_time))
        |> add_stream_specifier(stream_type: :video)
        |> add_stream_option(option_map("0:v:0?"))
        |> add_stream_option(option_c("libx264"))
        |> add_stream_option(option_preset("medium"))
        |> add_stream_option(option_crf(23))
        |> add_stream_option(option_pix_fmt("yuv420p"))
        |> add_stream_specifier(stream_type: :audio)
        |> add_stream_option(option_map("0:a:0?"))
        |> add_stream_option(option_c("aac"))
        |> add_stream_option(option_b("128k"))
        |> add_file_option(option_movflags("+faststart"))
        |> add_file_option(option_y())
        |> add_output_file(output_path)

      case FFmpex.execute(command) do
        {:ok, _output} ->
          # Verify the file was created and get its size
          case File.stat(output_path) do
            {:ok, %File.Stat{size: file_size}} ->
              {:ok, file_size}
            {:error, reason} ->
              {:error, "Created clip file not found: #{reason}"}
          end
        {:error, reason} ->
          {:error, "FFmpeg error: #{reason}"}
      end
    rescue
      e ->
        {:error, "Exception creating video clip: #{inspect(e)}"}
    end
  end

  @spec upload_split_clips(list(map()), Clip.t()) :: {:ok, list(map())} | {:error, any()}
  defp upload_split_clips(created_clips, %Clip{source_video_id: source_video_id, id: _clip_id}) do
    bucket_name = get_s3_bucket_name()
    output_prefix = "source_videos/#{source_video_id}/clips/splits"

    uploaded_clips =
      created_clips
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {clip_data, index}, acc ->
        s3_key = "#{output_prefix}/#{clip_data.filename}"
        local_path = clip_data.local_path

        Logger.info("Split: Uploading #{clip_data.filename} to s3://#{bucket_name}/#{s3_key}")

        case ExAws.S3.Upload.stream_file(local_path)
             |> ExAws.S3.upload(bucket_name, s3_key)
             |> ExAws.request() do
          {:ok, _result} ->
            uploaded_clip = Map.put(clip_data, :s3_key, s3_key)
            {:cont, [uploaded_clip | acc]}
          {:error, reason} ->
            Logger.error("Split: Failed to upload #{clip_data.filename}: #{inspect(reason)}")
            {:halt, {:error, "Failed to upload clip #{index + 1}: #{inspect(reason)}"}}
        end
      end)

    case uploaded_clips do
      {:error, reason} -> {:error, reason}
      clips when is_list(clips) -> {:ok, Enum.reverse(clips)}
    end
  end

  @spec cleanup_original_file(Clip.t()) :: {:ok, map()} | {:error, any()}
  defp cleanup_original_file(%Clip{clip_filepath: s3_path}) do
    Logger.info("Split: Cleaning up original source file: #{s3_path}")

    s3_key = String.trim_leading(s3_path, "/")

    case S3.delete_s3_objects([s3_key]) do
      {:ok, deleted_count} ->
        {:ok, %{deleted_count: deleted_count, error_count: 0}}
      {:error, reason} ->
        Logger.warning("Split: Failed to cleanup original file #{s3_path}: #{inspect(reason)}")
        # Don't fail the entire operation due to cleanup failure
        {:ok, %{deleted_count: 0, error_count: 1}}
    end
  end

  @spec create_clip_records(list(map()), Clip.t()) :: {:ok, list(Clip.t())} | {:error, any()}
  defp create_clip_records(uploaded_clips, original_clip) do
    now = DateTime.utc_now()

    clips_attrs =
      Enum.map(uploaded_clips, fn clip_data ->
        %{
          clip_filepath: "/#{clip_data.s3_key}",
          clip_identifier: clip_data.clip_identifier,
          start_frame: clip_data.start_frame,
          end_frame: clip_data.end_frame,
          start_time_seconds: clip_data.start_time_seconds,
          end_time_seconds: clip_data.end_time_seconds,
          ingest_state: "spliced",
          source_video_id: original_clip.source_video_id,
          processing_metadata: %{
            created_from_split: true,
            original_clip_id: original_clip.id,
            file_size: clip_data.file_size,
            duration_seconds: clip_data.duration_seconds
          },
          inserted_at: now,
          updated_at: now
        }
      end)

    case Repo.insert_all(Clip, clips_attrs, returning: true) do
      {count, clips} when count > 0 ->
        Logger.info("Split: Created #{count} new clip records")
        {:ok, clips}
      {0, _} ->
        {:error, "Failed to create clip records"}
    end
  rescue
    e ->
      Logger.error("Split: Error creating clip records: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @spec update_original_clip_state(integer()) :: :ok | {:error, any()}
  defp update_original_clip_state(clip_id) do
    case ClipQueries.get_clip(clip_id) do
      {:ok, clip} ->
        case ClipQueries.update_clip(clip, %{ingest_state: "review_archived"}) do
          {:ok, _updated_clip} ->
            Logger.info("Split: Updated original clip #{clip_id} to review_archived state")
            :ok
          {:error, reason} ->
            Logger.error("Split: Failed to update original clip state: #{inspect(reason)}")
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end
end
