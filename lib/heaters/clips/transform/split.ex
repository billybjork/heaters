defmodule Heaters.Clips.Transform.Split do
  @moduledoc """
  Video split operations - pure business logic.

  Splits video clips at specified frame boundaries, creating two separate clips
  when the resulting segments meet minimum duration requirements.

  Uses shared infrastructure modules for FFmpeg operations, S3 handling, and
  temporary file management.
  """

  require Logger

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Infrastructure.S3
  alias Heaters.Clips.Transform.Shared.{Types, TempManager, FFmpegRunner}
  alias Heaters.Utils

  # Business configuration matching original split.py
  @min_clip_duration_seconds 0.5

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
  Splits a clip at the specified frame, creating two separate clips.

  ## Parameters
  - `clip_id`: The ID of the clip to split
  - `split_at_frame`: The frame number where to split the video

  ## Returns
  - `{:ok, SplitResult.t()}` on success with created clip data
  - `{:error, reason}` on failure
  """
  @spec run_split(integer(), integer()) :: {:ok, Types.SplitResult.t()} | {:error, any()}
  def run_split(clip_id, split_at_frame) do
    Logger.info("Split: Starting split for clip_id: #{clip_id} at frame: #{split_at_frame}")

    TempManager.with_temp_directory("split", fn temp_dir ->
      with {:ok, clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
           {:ok, split_params} <- build_split_params(clip, split_at_frame),
           {:ok, local_video_path} <- download_source_video(clip, temp_dir),
           {:ok, created_clips} <- split_video_file(local_video_path, temp_dir, split_params),
           {:ok, uploaded_clips} <- upload_split_clips(created_clips, clip),
           {:ok, cleanup_result} <- cleanup_original_file(clip),
           {:ok, new_clip_records} <- create_clip_records(uploaded_clips, clip),
           :ok <- update_original_clip_state(clip_id) do
        result = %Types.SplitResult{
          status: "success",
          original_clip_id: clip_id,
          new_clip_ids: Enum.map(new_clip_records, & &1.id),
          created_clips: uploaded_clips,
          cleanup: cleanup_result,
          metadata: %{
            split_at_frame: split_at_frame,
            clips_created: length(new_clip_records),
            total_duration: Enum.reduce(uploaded_clips, 0.0, &(&1.duration_seconds + &2))
          },
          duration_ms: nil,
          processed_at: DateTime.utc_now()
        }

        Logger.info("Split: Successfully completed split for clip_id: #{clip_id}")
        {:ok, result}
      else
        error ->
          Logger.error("Split: Failed to split clip_id: #{clip_id}, error: #{inspect(error)}")
          error
      end
    end)
  end

  ## Private functions implementing split-specific business logic

  @spec build_split_params(Clip.t(), integer()) :: {:ok, split_params()} | {:error, any()}
  defp build_split_params(%Clip{} = clip, split_at_frame) do
    if is_nil(clip.source_video) do
      {:error, "Clip has no associated source video"}
    else
      fps = get_video_fps_from_metadata(clip) || 30.0

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
        {:error,
         "Split frame #{split_at_frame} is outside clip range (#{clip.start_frame}-#{clip.end_frame})"}
      end
    end
  end

  @spec get_video_fps_from_metadata(Clip.t()) :: float() | nil
  defp get_video_fps_from_metadata(%Clip{processing_metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "fps") || Map.get(metadata, :fps)
  end

  defp get_video_fps_from_metadata(_clip), do: nil

  @spec download_source_video(Clip.t(), String.t()) :: {:ok, String.t()} | {:error, any()}
  defp download_source_video(%Clip{clip_filepath: s3_path}, temp_dir) do
    local_filename = Path.basename(s3_path)
    local_path = Path.join(temp_dir, local_filename)

    Logger.info("Split: Downloading #{s3_path} to #{local_path}")

    s3_key = String.trim_leading(s3_path, "/")

    case S3.download_file(s3_key, local_path, operation_name: "Split") do
      {:ok, ^local_path} ->
        {:ok, local_path}

      {:error, reason} ->
        Logger.error("Split: Failed to download from S3: #{inspect(reason)}")
        {:error, "Failed to download from S3: #{inspect(reason)}"}
    end
  end

  @spec split_video_file(String.t(), String.t(), split_params()) ::
          {:ok, list(map())} | {:error, any()}
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

    # Get FPS from video file if not provided in metadata
    fps =
      if fps && fps > 0 do
        fps
      else
        case FFmpegRunner.get_video_fps(source_video_path) do
          {:ok, detected_fps} -> detected_fps
        end
      end

    Logger.info("Split: Splitting video at frame #{split_at_frame} (FPS: #{Float.round(fps, 3)})")

    # Calculate split time
    split_time_abs = split_at_frame / fps
    sanitized_source_title = Utils.sanitize_filename(source_title)

    # Create clips before and after split point
    with {:ok, clip_a} <-
           create_clip_before_split(
             source_video_path,
             output_dir,
             sanitized_source_title,
             original_start_time,
             split_time_abs,
             original_start_frame,
             split_at_frame - 1
           ),
         {:ok, clip_b} <-
           create_clip_after_split(
             source_video_path,
             output_dir,
             sanitized_source_title,
             split_time_abs,
             original_end_time,
             split_at_frame,
             original_end_frame
           ) do
      # Remove nil values
      created_clips = [clip_a, clip_b] |> Enum.filter(& &1)

      if Enum.empty?(created_clips) do
        {:error, "Split operation did not create any valid clips"}
      else
        {:ok, created_clips}
      end
    else
      error -> error
    end
  end

  @spec create_clip_before_split(
          String.t(),
          String.t(),
          String.t(),
          float(),
          float(),
          integer(),
          integer()
        ) ::
          {:ok, map() | nil} | {:error, any()}
  defp create_clip_before_split(
         source_video_path,
         output_dir,
         sanitized_source_title,
         start_time,
         end_time,
         start_frame,
         end_frame
       ) do
    duration = end_time - start_time

    if duration >= @min_clip_duration_seconds do
      clip_id = "#{sanitized_source_title}_#{start_frame}_#{end_frame}"
      filename = "#{clip_id}.mp4"
      output_path = Path.join(output_dir, filename)

      case FFmpegRunner.create_video_clip(source_video_path, output_path, start_time, end_time) do
        {:ok, file_size} ->
          clip_data = %{
            clip_identifier: clip_id,
            filename: filename,
            local_path: output_path,
            start_time_seconds: start_time,
            end_time_seconds: end_time,
            start_frame: start_frame,
            end_frame: end_frame,
            duration_seconds: duration,
            file_size: file_size
          }

          Logger.info("Split: Created clip A: #{filename} (#{Float.round(duration, 2)}s)")
          {:ok, clip_data}

        {:error, reason} ->
          Logger.error("Split: Failed to create clip A: #{reason}")
          {:error, reason}
      end
    else
      Logger.info("Split: Skipping clip A - too short (#{duration}s)")
      {:ok, nil}
    end
  end

  @spec create_clip_after_split(
          String.t(),
          String.t(),
          String.t(),
          float(),
          float(),
          integer(),
          integer()
        ) ::
          {:ok, map() | nil} | {:error, any()}
  defp create_clip_after_split(
         source_video_path,
         output_dir,
         sanitized_source_title,
         start_time,
         end_time,
         start_frame,
         end_frame
       ) do
    duration = end_time - start_time

    if duration >= @min_clip_duration_seconds do
      clip_id = "#{sanitized_source_title}_#{start_frame}_#{end_frame}"
      filename = "#{clip_id}.mp4"
      output_path = Path.join(output_dir, filename)

      case FFmpegRunner.create_video_clip(source_video_path, output_path, start_time, end_time) do
        {:ok, file_size} ->
          clip_data = %{
            clip_identifier: clip_id,
            filename: filename,
            local_path: output_path,
            start_time_seconds: start_time,
            end_time_seconds: end_time,
            start_frame: start_frame,
            end_frame: end_frame,
            duration_seconds: duration,
            file_size: file_size
          }

          Logger.info("Split: Created clip B: #{filename} (#{Float.round(duration, 2)}s)")
          {:ok, clip_data}

        {:error, reason} ->
          Logger.error("Split: Failed to create clip B: #{reason}")
          {:error, reason}
      end
    else
      Logger.info("Split: Skipping clip B - too short (#{duration}s)")
      {:ok, nil}
    end
  end

  @spec upload_split_clips(list(map()), Clip.t()) :: {:ok, list(map())} | {:error, any()}
  defp upload_split_clips(created_clips, %Clip{source_video_id: source_video_id}) do
    output_prefix = "source_videos/#{source_video_id}/clips/splits"

    uploaded_clips =
      created_clips
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {clip_data, index}, acc ->
        s3_key = "#{output_prefix}/#{clip_data.filename}"

        case S3.get_bucket_name() do
          {:ok, bucket_name} ->
            Logger.info("Split: Uploading #{clip_data.filename} to s3://#{bucket_name}/#{s3_key}")

          {:error, _} ->
            Logger.info("Split: Uploading #{clip_data.filename} to s3://[bucket_error]/#{s3_key}")
        end

        case S3.upload_file(clip_data.local_path, s3_key, operation_name: "Split") do
          {:ok, ^s3_key} ->
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
