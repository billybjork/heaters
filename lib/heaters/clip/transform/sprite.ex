defmodule Heaters.Clip.Transform.Sprite do
  @moduledoc """
  Sprite sheet generation operations using FFmpeg via ffmpex.

  This module replicates the functionality from sprite.py, handling:
  - Downloading clip videos from S3
  - Extracting video metadata using ffprobe
  - Generating sprite sheets using ffmpeg
  - Uploading sprite artifacts to S3
  - Managing clip state transitions
  """

  import FFmpex
  use FFmpex.Options

  alias Heaters.Clips.Clip
  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Utils
  require Logger

  # Configuration constants matching sprite.py
  @sprite_tile_width 480
  @sprite_tile_height -1  # -1 preserves aspect ratio
  @sprite_fps 24
  @sprite_cols 5
  @jpeg_quality 3  # FFmpeg qscale:v value (lower = better quality)

  @type sprite_params :: %{
    tile_width: integer(),
    tile_height: integer(),
    fps: integer(),
    cols: integer()
  }

  @type sprite_result :: %{
    status: String.t(),
    artifacts: list(map()),
    metadata: map()
  }

  @doc """
  Main entry point for generating a sprite sheet for a clip.

  This function orchestrates the entire sprite generation process:
  1. Downloads the clip video from S3
  2. Extracts video metadata using ffprobe
  3. Generates a sprite sheet using ffmpeg
  4. Uploads the sprite sheet to S3
  5. Returns structured data about the sprite artifact

  Args:
    clip_id: The ID of the clip for sprite generation
    sprite_params: Optional sprite generation parameters

  Returns:
    {:ok, result} on success with sprite artifact data
    {:error, reason} on failure
  """
  @spec run_sprite(integer(), map()) :: {:ok, sprite_result()} | {:error, any()}
  def run_sprite(clip_id, sprite_params \\ %{}) do
    Logger.info("Sprite: Starting sprite generation for clip_id: #{clip_id}")

    with {:ok, temp_dir} <- create_temp_directory() do
      try do
        with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
             {:ok, final_sprite_params} <- build_sprite_params(sprite_params),
             {:ok, local_video_path} <- download_clip_video(clip, temp_dir),
             {:ok, video_metadata} <- get_video_metadata(local_video_path),
             {:ok, sprite_data} <- generate_sprite_sheet(local_video_path, temp_dir, clip_id, final_sprite_params, video_metadata),
             {:ok, uploaded_sprite_data} <- upload_sprite_sheet(sprite_data, clip) do

          result = %{
            status: "success",
            artifacts: [%{
              artifact_type: "sprite_sheet",
              s3_key: uploaded_sprite_data.s3_key,
              metadata: uploaded_sprite_data.metadata
            }],
            metadata: %{
              clip_id: clip_id,
              sprite_generated: true
            }
          }

          Logger.info("Sprite: Successfully completed sprite generation for clip_id: #{clip_id}")
          {:ok, result}
        else
          error ->
            Logger.error("Sprite: Failed to generate sprite for clip_id: #{clip_id}, error: #{inspect(error)}")
            error
        end
      after
        Logger.info("Sprite: Cleaning up temp directory: #{temp_dir}")
        File.rm_rf(temp_dir)
      end
    else
      error ->
        Logger.error("Sprite: Could not create temp directory: #{inspect(error)}")
        error
    end
  end

  # Private functions implementing the core sprite logic

  @spec build_sprite_params(map()) :: {:ok, sprite_params()} | {:error, any()}
  defp build_sprite_params(input_params) do
    sprite_params = %{
      tile_width: Map.get(input_params, :tile_width, @sprite_tile_width),
      tile_height: Map.get(input_params, :tile_height, @sprite_tile_height),
      fps: Map.get(input_params, :sprite_fps, @sprite_fps),
      cols: Map.get(input_params, :cols, @sprite_cols)
    }

    {:ok, sprite_params}
  end

  @spec create_temp_directory() :: {:ok, String.t()} | {:error, any()}
  defp create_temp_directory do
    case System.tmp_dir() do
      nil -> {:error, "Could not access system temp directory"}
      temp_root ->
        temp_dir = Path.join(temp_root, "heaters_sprite_#{System.unique_integer([:positive])}")
        case File.mkdir_p(temp_dir) do
          :ok -> {:ok, temp_dir}
          {:error, reason} -> {:error, "Failed to create temp directory: #{reason}"}
        end
    end
  end

  @spec download_clip_video(Clip.t(), String.t()) :: {:ok, String.t()} | {:error, any()}
  defp download_clip_video(%Clip{clip_filepath: s3_path} = _clip, temp_dir) do
    local_filename = Path.basename(s3_path)
    local_path = Path.join(temp_dir, local_filename)

    Logger.info("Sprite: Downloading #{s3_path} to #{local_path}")

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
        Logger.error("Sprite: Failed to stream download from S3: #{Exception.message(error)}")
        {:error, "Failed to download from S3: #{Exception.message(error)}"}
    end
  end

  @spec get_video_metadata(String.t()) :: {:ok, map()} | {:error, any()}
  defp get_video_metadata(video_path) do
    Logger.info("Sprite: Probing video metadata: #{video_path}")

    try do
      # Use System.cmd to call ffprobe directly to get detailed metadata
      # Replicating: ffprobe -v error -select_streams v:0 -show_entries stream=duration,r_frame_rate,nb_frames -count_frames -of json video_path
      {output, exit_code} = System.cmd("ffprobe", [
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=duration,r_frame_rate,nb_frames",
        "-count_frames",
        "-of", "json",
        video_path
      ])

      if exit_code == 0 do
        case Jason.decode(output) do
          {:ok, %{"streams" => [probe_data | _]}} ->
            parse_video_metadata(probe_data, video_path)
          {:ok, %{"streams" => []}} ->
            {:error, "ffprobe found no video streams in #{video_path}"}
          {:error, reason} ->
            {:error, "Failed to parse ffprobe JSON output: #{inspect(reason)}"}
        end
      else
        Logger.error("Sprite: FFprobe command failed with exit code #{exit_code}")
        {:error, "FFprobe command failed with exit code #{exit_code}"}
      end
    rescue
      e ->
        Logger.error("Sprite: Exception getting video metadata: #{Exception.message(e)}")
        {:error, "Exception getting video metadata: #{Exception.message(e)}"}
    end
  end

  @spec parse_video_metadata(map(), String.t()) :: {:ok, map()} | {:error, any()}
  defp parse_video_metadata(probe_data, _video_path) do
    Logger.debug("Sprite: ffprobe result: #{inspect(probe_data)}")

    with {:ok, duration} <- extract_duration(probe_data),
         {:ok, fps} <- extract_fps(probe_data),
         {:ok, total_frames} <- extract_total_frames(probe_data, duration, fps) do

      if duration <= 0 or fps <= 0 or total_frames <= 0 do
        {:error, "Invalid video metadata: duration=#{duration}s, fps=#{fps}, frames=#{total_frames}"}
      else
        metadata = %{
          duration: duration,
          fps: fps,
          total_frames: total_frames
        }
        {:ok, metadata}
      end
    else
      error -> error
    end
  end

  defp extract_duration(%{"duration" => duration_str}) when is_binary(duration_str) do
    case Float.parse(duration_str) do
      {duration, ""} -> {:ok, duration}
      _ -> {:error, "Could not parse duration: #{duration_str}"}
    end
  end
  defp extract_duration(_), do: {:error, "Could not determine video duration"}

  defp extract_fps(%{"r_frame_rate" => fps_str}) when is_binary(fps_str) do
    case String.split(fps_str, "/") do
      [num_str, den_str] ->
        with {num, ""} <- Integer.parse(num_str),
             {den, ""} <- Integer.parse(den_str),
             true <- den > 0 do
          {:ok, num / den}
        else
          _ -> {:error, "Invalid frame rate: #{fps_str}"}
        end
      _ ->
        case Float.parse(fps_str) do
          {fps, ""} -> {:ok, fps}
          _ -> {:error, "Could not parse frame rate: #{fps_str}"}
        end
    end
  end
  defp extract_fps(_), do: {:error, "Could not determine frame rate"}

  defp extract_total_frames(%{"nb_frames" => nb_frames_str}, _duration, _fps) when is_binary(nb_frames_str) do
    case Integer.parse(nb_frames_str) do
      {total_frames, ""} when total_frames > 0 ->
        Logger.info("Sprite: Using ffprobe nb_frames: #{total_frames}")
        {:ok, total_frames}
      _ ->
        {:error, "Invalid nb_frames: #{nb_frames_str}"}
    end
  end
  defp extract_total_frames(_, duration, fps) do
    # Calculate from duration and fps as fallback
    total_frames = ceil(duration * fps)
    Logger.info("Sprite: Calculated total frames from duration*fps: #{total_frames}")
    {:ok, total_frames}
  end

  @spec generate_sprite_sheet(String.t(), String.t(), integer(), sprite_params(), map()) :: {:ok, map()} | {:error, any()}
  defp generate_sprite_sheet(video_path, output_dir, clip_id, sprite_params, video_metadata) do
    %{
      tile_width: tile_width,
      tile_height: tile_height,
      fps: sprite_fps,
      cols: cols
    } = sprite_params

    %{
      duration: duration,
      fps: video_fps,
      total_frames: _total_frames
    } = video_metadata

    # Calculate sprite parameters using video's native FPS
    effective_sprite_fps = min(video_fps, sprite_fps)  # Don't exceed video's native FPS
    num_sprite_frames = ceil(duration * effective_sprite_fps)

    if num_sprite_frames <= 0 do
      {:error, "Video too short for sprite generation: #{duration}s"}
    else
      # Generate output filename
      clip_identifier = "clip_#{clip_id}"
      base_filename = Utils.sanitize_filename("#{clip_identifier}_sprite")
      timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
      output_filename = "#{base_filename}_#{trunc(effective_sprite_fps)}fps_w#{tile_width}_c#{cols}_#{timestamp}.jpg"
      final_output_path = Path.join(output_dir, output_filename)

      # Calculate grid dimensions
      num_rows = max(1, ceil(num_sprite_frames / cols))

      Logger.info("Sprite: Generating sprite sheet: #{output_filename}")
      Logger.info("Sprite: Parameters - fps: #{effective_sprite_fps}, frames: #{num_sprite_frames}, grid: #{cols}x#{num_rows}")

      case create_sprite_with_ffmpeg(video_path, final_output_path, effective_sprite_fps, tile_width, tile_height, cols, num_rows) do
        {:ok, file_size} ->
          sprite_data = %{
            local_path: final_output_path,
            filename: output_filename,
            file_size: file_size,
            sprite_metadata: %{
              effective_fps: effective_sprite_fps,
              num_frames: num_sprite_frames,
              cols: cols,
              rows: num_rows,
              tile_width: tile_width,
              tile_height: tile_height,
              video_duration: duration,
              video_fps: video_fps
            }
          }
          {:ok, sprite_data}
        error -> error
      end
    end
  end

  @spec create_sprite_with_ffmpeg(String.t(), String.t(), float(), integer(), integer(), integer(), integer()) :: {:ok, integer()} | {:error, any()}
  defp create_sprite_with_ffmpeg(input_path, output_path, sprite_fps, tile_width, tile_height, cols, num_rows) do
    try do
      # Build FFmpeg video filter matching the Python implementation:
      # vf_option = f"fps={effective_sprite_fps},scale={tile_width}:{tile_height}:flags=neighbor,tile={cols}x{num_rows}"
      vf_filter = "fps=#{sprite_fps},scale=#{tile_width}:#{tile_height}:flags=neighbor,tile=#{cols}x#{num_rows}"

      # Create FFmpeg command matching the Python implementation exactly:
      # ffmpeg -y -i input -vf "fps=...,scale=...,tile=..." -an -qscale:v 3 output.jpg
      command =
        FFmpex.new_command()
        |> add_global_option(option_y())  # Overwrite output file
        |> add_input_file(input_path)
        |> add_output_file(output_path)
        |> add_file_option(option_vf(vf_filter))
        |> add_file_option(option_an())  # No audio
        |> add_file_option(option_qscale("#{@jpeg_quality}:v"))

      case FFmpex.execute(command) do
        {:ok, _output} ->
          # Verify the file was created and get its size
          case File.stat(output_path) do
            {:ok, %File.Stat{size: file_size}} ->
              Logger.info("Sprite: Successfully generated sprite sheet: #{Path.basename(output_path)} (#{file_size} bytes)")
              {:ok, file_size}
            {:error, reason} ->
              {:error, "Created sprite file not found: #{reason}"}
          end
        {:error, reason} ->
          Logger.error("Sprite: FFmpeg failed: #{inspect(reason)}")
          {:error, "FFmpeg sprite generation failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        {:error, "Exception creating sprite sheet: #{inspect(e)}"}
    end
  end

  @spec upload_sprite_sheet(map(), Clip.t()) :: {:ok, map()} | {:error, any()}
  defp upload_sprite_sheet(sprite_data, %Clip{source_video_id: source_video_id, id: clip_id}) do
    bucket_name = get_s3_bucket_name()
    output_prefix = "source_videos/#{source_video_id}/clips/#{clip_id}/sprites"
    s3_key = "#{output_prefix}/#{sprite_data.filename}"

    Logger.info("Sprite: Uploading sprite sheet to s3://#{bucket_name}/#{s3_key}")

    case ExAws.S3.Upload.stream_file(sprite_data.local_path)
         |> ExAws.S3.upload(bucket_name, s3_key)
         |> ExAws.request() do
      {:ok, _result} ->
        uploaded_sprite_data = %{
          s3_key: s3_key,
          metadata: %{
            file_size: sprite_data.file_size,
            filename: sprite_data.filename
          } |> Map.merge(sprite_data.sprite_metadata)
        }
        {:ok, uploaded_sprite_data}
      {:error, reason} ->
        Logger.error("Sprite: Failed to upload sprite sheet: #{inspect(reason)}")
        {:error, "Failed to upload sprite sheet: #{inspect(reason)}"}
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
end
