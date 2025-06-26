defmodule Heaters.Clips.Operations.Merge do
  @moduledoc """
  Video merging operations - I/O orchestration layer.

  Handles merging two clips using FFmpeg concat functionality and manages
  the database state transitions for the merge workflow.

  Uses domain modules for business logic and infrastructure adapters for I/O operations.
  """

  import Ecto.Query, only: [from: 2]

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.Operations.Shared.{TempManager, Types, FFmpegRunner}

  # Domain modules (pure business logic)
  alias Heaters.Clips.Operations.Merge.{Calculations, Validation, FileNaming}
  alias Heaters.Clips.Operations.Shared.ResultBuilding

  # Infrastructure adapters (I/O operations)
  alias Heaters.Infrastructure.Adapters.{DatabaseAdapter, S3Adapter}

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
      with {:ok, target_clip} <- fetch_clip_data(target_clip_id),
           {:ok, source_clip} <- fetch_clip_data(source_clip_id),
           :ok <-
             validate_merge_requirements(target_clip_id, source_clip_id, target_clip, source_clip),
           {:ok, merge_spec} <- build_merge_specification(target_clip, source_clip),
           {:ok, local_target_path} <- download_clip_video(target_clip, temp_dir, "target"),
           {:ok, local_source_path} <- download_clip_video(source_clip, temp_dir, "source"),
           {:ok, merged_video_data} <-
             merge_video_files(local_target_path, local_source_path, temp_dir, merge_spec),
           {:ok, uploaded_clip_data} <- upload_merged_clip(merged_video_data, target_clip),
           {:ok, merged_clip_record} <- create_merged_clip_record(uploaded_clip_data, merge_spec),
           {:ok, _updated_count} <- update_source_clips_state(target_clip_id, source_clip_id),
           {:ok, cleanup_result} <- cleanup_source_files([target_clip, source_clip]) do
        result =
          build_success_result(merged_clip_record, target_clip_id, source_clip_id, cleanup_result)

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

  ## Private functions - I/O orchestration using Domain and Infrastructure layers

  @spec fetch_clip_data(integer()) :: {:ok, Clip.t()} | {:error, any()}
  defp fetch_clip_data(clip_id) do
    DatabaseAdapter.get_clip_with_artifacts(clip_id)
  end

  @spec validate_merge_requirements(integer(), integer(), Clip.t(), Clip.t()) ::
          :ok | {:error, String.t()}
  defp validate_merge_requirements(target_clip_id, source_clip_id, target_clip, source_clip) do
    Validation.validate_merge_requirements(
      target_clip_id,
      source_clip_id,
      target_clip,
      source_clip
    )
  end

  @spec build_merge_specification(Clip.t(), Clip.t()) ::
          {:ok, Calculations.merge_spec()} | {:error, String.t()}
  defp build_merge_specification(target_clip, source_clip) do
    Calculations.build_merge_spec(target_clip, source_clip)
  end

  @spec download_clip_video(Clip.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, any()}
  defp download_clip_video(clip, temp_dir, prefix) do
    local_filename = FileNaming.generate_local_filename(clip, prefix)
    Logger.info("Merge: Downloading #{clip.clip_filepath} to #{local_filename}")

    S3Adapter.download_clip_video(clip, temp_dir, local_filename)
  end

  @spec merge_video_files(String.t(), String.t(), String.t(), Calculations.merge_spec()) ::
          {:ok, map()} | {:error, any()}
  defp merge_video_files(target_video_path, source_video_path, output_dir, merge_spec) do
    # Create concat list file
    concat_list_path = Path.join(output_dir, "concat_list.txt")
    concat_content = FileNaming.generate_concat_list_content(target_video_path, source_video_path)

    case File.write(concat_list_path, concat_content) do
      :ok ->
        # Generate output filename
        filename =
          FileNaming.generate_merge_filename(merge_spec.target_clip, merge_spec.source_clip)

        final_output_path = Path.join(output_dir, filename)

        Logger.info("Merge: Merging videos into #{filename}")
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
                   filename: filename,
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

  @spec upload_merged_clip(map(), Clip.t()) :: {:ok, map()} | {:error, any()}
  defp upload_merged_clip(merged_video_data, target_clip) do
    s3_key = FileNaming.generate_s3_key(target_clip, merged_video_data.filename)

    case S3Adapter.upload_file(merged_video_data.local_path, s3_key, "Merge") do
      {:ok, ^s3_key} ->
        {:ok, Map.put(merged_video_data, :s3_key, s3_key)}

      {:error, reason} ->
        Logger.error("Merge: Failed to upload merged video: #{inspect(reason)}")
        {:error, "Failed to upload merged video: #{inspect(reason)}"}
    end
  end

  @spec create_merged_clip_record(map(), Calculations.merge_spec()) ::
          {:ok, Clip.t()} | {:error, any()}
  defp create_merged_clip_record(uploaded_clip_data, merge_spec) do
    %{target_clip: target_clip, source_clip: source_clip, timeline: timeline} = merge_spec

    clip_identifier = FileNaming.generate_clip_identifier(target_clip, source_clip)

    processing_metadata =
      FileNaming.generate_processing_metadata(
        target_clip,
        source_clip,
        clip_identifier,
        uploaded_clip_data.file_size
      )

    attrs = %{
      source_video_id: merge_spec.source_video_id,
      # Back to spliced to generate a new sprite
      ingest_state: "spliced",
      start_frame: timeline.new_start_frame,
      end_frame: timeline.new_end_frame,
      start_time_seconds: timeline.new_start_time,
      end_time_seconds: timeline.new_end_time,
      clip_filepath: uploaded_clip_data.s3_key,
      clip_identifier: clip_identifier,
      processing_metadata: processing_metadata
    }

    %Clip{}
    |> Clip.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_source_clips_state(integer(), integer()) :: {:ok, integer()} | {:error, any()}
  defp update_source_clips_state(target_clip_id, source_clip_id) do
    try do
      query = from(c in Clip, where: c.id in [^target_clip_id, ^source_clip_id])

      case Repo.update_all(query, set: [ingest_state: "merged", clip_filepath: nil]) do
        {count, _} ->
          Logger.info("Merge: Updated #{count} source clips to merged state")
          {:ok, count}
      end
    rescue
      e ->
        reason = "Failed to update source clips state: #{Exception.message(e)}"
        Logger.error("Merge: " <> reason)
        {:error, reason}
    end
  end

  @spec cleanup_source_files(list(Clip.t())) :: {:ok, integer()} | {:error, any()}
  defp cleanup_source_files(clips) do
    s3_paths = Enum.map(clips, & &1.clip_filepath)
    Logger.info("Merge: Cleaning up source files after successful merge: #{inspect(s3_paths)}")

    # Use S3Adapter for consistent error handling
    case delete_multiple_files(s3_paths) do
      {:ok, count} = result ->
        Logger.info("Merge: Successfully deleted #{count} source files from S3")
        result

      {:error, reason} = error ->
        Logger.error("Merge: Failed to delete source files from S3: #{inspect(reason)}")
        error
    end
  end

  @spec delete_multiple_files(list(String.t())) :: {:ok, integer()} | {:error, any()}
  defp delete_multiple_files(s3_paths) do
    # Convert to S3 keys and use existing S3 delete function
    s3_keys = Enum.map(s3_paths, &String.trim_leading(&1, "/"))

    case S3Adapter.delete_multiple_files(s3_keys) do
      {:ok, count} -> {:ok, count}
      error -> error
    end
  end

  @spec build_success_result(Clip.t(), integer(), integer(), integer()) :: Types.MergeResult.t()
  defp build_success_result(merged_clip_record, target_clip_id, source_clip_id, deleted_count) do
    metadata =
      Calculations.calculate_merge_result_metadata(
        merged_clip_record,
        target_clip_id,
        source_clip_id
      )

    cleanup_result = %{deleted_count: deleted_count, error_count: 0}

    ResultBuilding.build_merge_result(
      merged_clip_record.id,
      [target_clip_id, source_clip_id],
      cleanup_result,
      metadata
    )
  end
end
