defmodule Heaters.Clips.Transform.Merge do
  @moduledoc """
  Video merging operations for combining two clips into one.

  Handles merging two clips using FFmpeg concat functionality and manages
  the database state transitions for the merge workflow.
  """

  import Ecto.Query, only: [from: 2]

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Clips.Transform.Shared.{TempManager, Types, FFmpegRunner}
  alias Heaters.Infrastructure.S3
  alias Heaters.Utils
  require Logger

  @doc """
  Main entry point for merging two clips.

  Orchestrates the entire merge process:
  1. Downloads source videos from S3
  2. Merges them using ffmpeg
  3. Uploads the new clip to S3
  4. Cleans up original files
  5. Updates database state
  """
  @spec run_merge(integer(), integer()) :: {:ok, Types.MergeResult.t()} | {:error, any()}
  def run_merge(target_clip_id, source_clip_id)
      when is_integer(target_clip_id) and is_integer(source_clip_id) do
    Logger.info(
      "Merge: Starting merge for target_clip_id: #{target_clip_id} and source_clip_id: #{source_clip_id}"
    )

    TempManager.with_temp_directory("heaters_merge", fn temp_dir ->
      with {:ok, target_clip} <- ClipQueries.get_clip_with_artifacts(target_clip_id),
           {:ok, source_clip} <- ClipQueries.get_clip_with_artifacts(source_clip_id),
           {:ok, local_target_path} <- download_clip_video(target_clip, temp_dir, "target"),
           {:ok, local_source_path} <- download_clip_video(source_clip, temp_dir, "source"),
           {:ok, merged_video_data} <-
             merge_video_files(local_target_path, local_source_path, temp_dir, target_clip),
           {:ok, uploaded_clip_data} <- upload_merged_clip(merged_video_data, target_clip),
           {:ok, merged_clip_record} <-
             create_merged_clip_record(uploaded_clip_data, target_clip, source_clip),
           {:ok, _updated_count} <- update_source_clips_state(target_clip_id, source_clip_id),
           {:ok, cleanup_result} <- cleanup_source_files([target_clip, source_clip]) do
        result = %Types.MergeResult{
          status: "success",
          merged_clip_id: merged_clip_record.id,
          source_clip_ids: [target_clip_id, source_clip_id],
          cleanup: cleanup_result,
          metadata: %{
            new_clip_id: merged_clip_record.id,
            new_duration:
              merged_clip_record.end_time_seconds - merged_clip_record.start_time_seconds
          },
          processed_at: DateTime.utc_now()
        }

        Logger.info(
          "Merge: Successfully completed merge for clips #{target_clip_id}, #{source_clip_id}"
        )

        {:ok, result}
      else
        {:error, reason} = error ->
          Logger.error(
            "Merge: Failed to merge clips #{target_clip_id}, #{source_clip_id}, error: #{inspect(reason)}"
          )

          error

        other_error ->
          Logger.error(
            "Merge: Failed to merge clips #{target_clip_id}, #{source_clip_id}, error: #{inspect(other_error)}"
          )

          {:error, other_error}
      end
    end)
  end

  defp download_clip_video(%Clip{clip_filepath: s3_path}, temp_dir, prefix) do
    local_filename = "#{prefix}_#{Path.basename(s3_path)}"
    local_path = Path.join(temp_dir, local_filename)
    Logger.info("Merge: Downloading #{s3_path} to #{local_path}")

    s3_key = String.trim_leading(s3_path, "/")
    S3.download_file(s3_key, local_path, operation_name: "Merge")
  end

  defp merge_video_files(target_video_path, source_video_path, output_dir, target_clip) do
    # Create concat list file
    concat_list_path = Path.join(output_dir, "concat_list.txt")

    concat_content = """
    file '#{Path.expand(target_video_path)}'
    file '#{Path.expand(source_video_path)}'
    """

    case File.write(concat_list_path, concat_content) do
      :ok ->
        # Generate output filename
        new_identifier =
          "merged_#{target_clip.id}_#{Path.basename(source_video_path, ".mp4") |> String.split("_") |> List.last()}"

        sanitized_identifier = Utils.sanitize_filename(new_identifier)
        output_filename = "#{sanitized_identifier}.mp4"
        final_output_path = Path.join(output_dir, output_filename)

        Logger.info("Merge: Merging videos into #{output_filename}")
        Logger.info("Merge: Created concat list at #{concat_list_path}")

        case FFmpegRunner.merge_videos(concat_list_path, final_output_path) do
          {:ok, _result} ->
            case File.stat(final_output_path) do
              {:ok, %{size: file_size}} ->
                Logger.info(
                  "Merge: Successfully merged videos. Output size: #{file_size} bytes at #{final_output_path}"
                )

                {:ok,
                 %{
                   local_path: final_output_path,
                   filename: output_filename,
                   file_size: file_size
                 }}

              {:error, reason} ->
                Logger.error("Merge: Failed to get file stats: #{inspect(reason)}")
                {:error, "Failed to get file stats: #{inspect(reason)}"}
            end

          {:error, reason} ->
            Logger.error("Merge: FFmpeg merge failed: #{inspect(reason)}")
            {:error, "FFmpeg merge failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("Merge: Failed to write concat list file: #{inspect(reason)}")
        {:error, "Failed to write concat list file: #{inspect(reason)}"}
    end
  end

  defp upload_merged_clip(merged_video_data, target_clip) do
    output_s3_prefix =
      Path.dirname(target_clip.clip_filepath)
      |> String.trim_leading("/")

    s3_key = "#{output_s3_prefix}/#{merged_video_data.filename}"

    case S3.get_bucket_name() do
      {:ok, bucket_name} ->
        Logger.info("Merge: Uploading merged video to s3://#{bucket_name}/#{s3_key}")

      {:error, _} ->
        Logger.info("Merge: Uploading merged video to s3://[bucket_error]/#{s3_key}")
    end

    case S3.upload_file(merged_video_data.local_path, s3_key, operation_name: "Merge") do
      {:ok, _result} ->
        {:ok, Map.put(merged_video_data, :s3_key, s3_key)}

      {:error, reason} ->
        Logger.error("Merge: Failed to upload merged video: #{inspect(reason)}")
        {:error, "Failed to upload merged video: #{inspect(reason)}"}
    end
  end

  defp create_merged_clip_record(uploaded_clip_data, target_clip, source_clip) do
    # The new clip continues the timeline from the target clip
    new_start_frame = target_clip.start_frame
    new_end_frame = target_clip.end_frame + (source_clip.end_frame - source_clip.start_frame)

    new_start_time = target_clip.start_time_seconds

    new_end_time =
      target_clip.end_time_seconds +
        (source_clip.end_time_seconds - source_clip.start_time_seconds)

    attrs = %{
      source_video_id: target_clip.source_video_id,
      # Back to spliced to generate a new sprite
      ingest_state: "spliced",
      start_frame: new_start_frame,
      end_frame: new_end_frame,
      start_time_seconds: new_start_time,
      end_time_seconds: new_end_time,
      clip_filepath: uploaded_clip_data.s3_key,
      clip_identifier: Path.basename(uploaded_clip_data.filename, ".mp4"),
      # Carry over metadata from the target clip
      processing_metadata:
        Map.merge(
          target_clip.processing_metadata || %{},
          %{
            merged_from_clips: [target_clip.id, source_clip.id],
            new_identifier: Path.basename(uploaded_clip_data.filename, ".mp4")
          }
        )
    }

    %Clip{}
    |> Clip.changeset(attrs)
    |> Repo.insert()
  end

  defp update_source_clips_state(target_clip_id, source_clip_id) do
    try do
      query = from(c in Clip, where: c.id in [^target_clip_id, ^source_clip_id])
      # Repo.update_all can raise an exception, so we wrap it in a try/rescue
      case Repo.update_all(query, set: [ingest_state: "merged", clip_filepath: nil]) do
        {count, _} ->
          Logger.info("Merge: Updated #{count} source clips to merged state")
          # Return a consistent success tuple
          {:ok, count}
      end
    rescue
      e ->
        reason = "Failed to update source clips state: #{Exception.message(e)}"
        Logger.error("Merge: " <> reason)
        {:error, reason}
    end
  end

  defp cleanup_source_files(clips) do
    s3_keys = Enum.map(clips, &String.trim_leading(&1.clip_filepath, "/"))
    Logger.info("Merge: Cleaning up source files after successful merge: #{inspect(s3_keys)}")

    case S3.delete_s3_objects(s3_keys) do
      {:ok, count} = result ->
        Logger.info("Merge: Successfully deleted #{count} source files from S3")
        result

      {:error, reason} = error ->
        Logger.error("Merge: Failed to delete source files from S3: #{inspect(reason)}")
        error
    end
  end
end
