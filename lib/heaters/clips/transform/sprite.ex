defmodule Heaters.Clips.Transform.Sprite do
  @moduledoc """
  Sprite sheet generation operations - pure business logic.

  Generates video sprite sheets (image grids) for preview purposes using
  configurable tile dimensions, frame sampling rates, and grid layouts.

  Uses shared infrastructure modules for FFmpeg operations, S3 handling, and
  temporary file management.
  """

  require Logger

  alias Heaters.Clips.Clip
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Infrastructure.S3
  alias Heaters.Clips.Transform.Shared.{Types, TempManager, FFmpegRunner}
  alias Heaters.Utils

  # Business configuration matching original sprite.py
  @sprite_tile_width 480
  # -1 preserves aspect ratio
  @sprite_tile_height -1
  @sprite_fps 24
  @sprite_cols 5

  @type sprite_params :: %{
          tile_width: integer(),
          tile_height: integer(),
          fps: integer(),
          cols: integer()
        }

  @doc """
  Generates a sprite sheet for the specified clip.

  ## Parameters
  - `clip_id`: The ID of the clip for sprite generation
  - `sprite_params`: Optional sprite generation parameters

  ## Returns
  - `{:ok, SpriteResult.t()}` on success with sprite artifact data
  - `{:error, reason}` on failure
  """
  @spec run_sprite(integer(), map()) :: {:ok, Types.SpriteResult.t()} | {:error, any()}
  def run_sprite(clip_id, sprite_params \\ %{}) do
    Logger.info("Sprite: Starting sprite generation for clip_id: #{clip_id}")

    TempManager.with_temp_directory("sprite", fn temp_dir ->
      with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
           {:ok, final_sprite_params} <- build_sprite_params(sprite_params),
           {:ok, local_video_path} <- download_clip_video(clip, temp_dir),
           {:ok, video_metadata} <- FFmpegRunner.get_video_metadata(local_video_path),
           {:ok, sprite_data} <-
             generate_sprite_sheet(
               local_video_path,
               temp_dir,
               clip_id,
               final_sprite_params,
               video_metadata
             ),
           {:ok, uploaded_sprite_data} <- upload_sprite_sheet(sprite_data, clip) do
        result = %Types.SpriteResult{
          status: "success",
          clip_id: clip_id,
          artifacts: [
            %{
              artifact_type: "sprite_sheet",
              s3_key: uploaded_sprite_data.s3_key,
              metadata: uploaded_sprite_data.metadata
            }
          ],
          metadata: %{
            sprite_generated: true
          },
          duration_ms: nil,
          processed_at: DateTime.utc_now()
        }

        Logger.info("Sprite: Successfully completed sprite generation for clip_id: #{clip_id}")
        {:ok, result}
      else
        error ->
          Logger.error(
            "Sprite: Failed to generate sprite for clip_id: #{clip_id}, error: #{inspect(error)}"
          )

          error
      end
    end)
  end

  ## Private functions implementing sprite-specific business logic

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

  @spec download_clip_video(Clip.t(), String.t()) :: {:ok, String.t()} | {:error, any()}
  defp download_clip_video(%Clip{clip_filepath: s3_path}, temp_dir) do
    local_filename = Path.basename(s3_path)
    local_path = Path.join(temp_dir, local_filename)

    Logger.info("Sprite: Downloading #{s3_path} to #{local_path}")

    s3_key = String.trim_leading(s3_path, "/")

    case S3.download_file(s3_key, local_path, operation_name: "Sprite") do
      {:ok, ^local_path} ->
        {:ok, local_path}

      {:error, reason} ->
        Logger.error("Sprite: Failed to download from S3: #{inspect(reason)}")
        {:error, "Failed to download from S3: #{inspect(reason)}"}
    end
  end

  @spec generate_sprite_sheet(String.t(), String.t(), integer(), sprite_params(), map()) ::
          {:ok, map()} | {:error, any()}
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
    # Don't exceed video's native FPS
    effective_sprite_fps = min(video_fps, sprite_fps)
    num_sprite_frames = ceil(duration * effective_sprite_fps)

    if num_sprite_frames <= 0 do
      {:error, "Video too short for sprite generation: #{duration}s"}
    else
      # Generate output filename
      clip_identifier = "clip_#{clip_id}"
      base_filename = Utils.sanitize_filename("#{clip_identifier}_sprite")
      timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()

      output_filename =
        "#{base_filename}_#{trunc(effective_sprite_fps)}fps_w#{tile_width}_c#{cols}_#{timestamp}.jpg"

      final_output_path = Path.join(output_dir, output_filename)

      # Calculate grid dimensions
      num_rows = max(1, ceil(num_sprite_frames / cols))

      Logger.info("Sprite: Generating sprite sheet: #{output_filename}")

      Logger.info(
        "Sprite: Parameters - fps: #{effective_sprite_fps}, frames: #{num_sprite_frames}, grid: #{cols}x#{num_rows}"
      )

      case FFmpegRunner.create_sprite_sheet(
             video_path,
             final_output_path,
             effective_sprite_fps,
             tile_width,
             tile_height,
             cols,
             num_rows
           ) do
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

        error ->
          error
      end
    end
  end

  @spec upload_sprite_sheet(map(), Clip.t()) :: {:ok, map()} | {:error, any()}
  defp upload_sprite_sheet(sprite_data, %Clip{source_video_id: source_video_id, id: clip_id}) do
    output_prefix = "source_videos/#{source_video_id}/clips/#{clip_id}/sprites"
    s3_key = "#{output_prefix}/#{sprite_data.filename}"

    case S3.get_bucket_name() do
      {:ok, bucket_name} ->
        Logger.info("Sprite: Uploading sprite sheet to s3://#{bucket_name}/#{s3_key}")

      {:error, _} ->
        Logger.info("Sprite: Uploading sprite sheet to s3://[bucket_error]/#{s3_key}")
    end

    case S3.upload_file(sprite_data.local_path, s3_key, operation_name: "Sprite") do
      {:ok, ^s3_key} ->
        uploaded_sprite_data = %{
          s3_key: s3_key,
          metadata:
            %{
              file_size: sprite_data.file_size,
              filename: sprite_data.filename
            }
            |> Map.merge(sprite_data.sprite_metadata)
        }

        {:ok, uploaded_sprite_data}

      {:error, reason} ->
        Logger.error("Sprite: Failed to upload sprite sheet: #{inspect(reason)}")
        {:error, "Failed to upload sprite sheet: #{inspect(reason)}"}
    end
  end
end
