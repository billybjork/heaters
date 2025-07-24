defmodule Heaters.Clips.Operations.Export.Worker do
  @moduledoc """
  Worker for exporting virtual clips to physical clips using the gold master.

  This worker handles the final stage of the virtual clip pipeline by encoding
  approved virtual clips into physical MP4 files using the lossless gold master.

  ## Workflow

  1. Group virtual clips by source_video for batch processing
  2. Download gold master file for the source video
  3. Extract individual clips using cut points and FFmpeg
  4. Upload physical clips to S3
  5. Update clip records: is_virtual = false, add clip_filepath
  6. Clean up temporary files

  ## State Management

  - **Input**: Virtual clips in "review_approved" state
  - **Output**: Physical clips with clip_filepath, is_virtual = false
  - **Error Handling**: Marks clips as "export_failed" on errors
  - **Idempotency**: Skip if is_virtual = false (already exported)

  ## Batch Processing

  For efficiency, this worker processes all approved virtual clips from the same
  source video together in a single job. This minimizes gold master downloads
  and temporary file operations.

  ## Architecture

  - **Export**: Python task via PyRunner port for FFmpeg operations
  - **State Management**: Elixir state transitions and database operations
  - **Storage**: S3 for physical clip files
  - **Cleanup**: Temporary file management
  """

  use Heaters.Infrastructure.Orchestration.WorkerBehavior,
    queue: :media_processing,
    # 30 minutes for large exports
    unique: [period: 1800, fields: [:args]]

  alias Heaters.Clips.Clip
  alias Heaters.Clips.Operations.Export.StateManager
  alias Heaters.Infrastructure.Orchestration.WorkerBehavior
  alias Heaters.Infrastructure.PyRunner
  require Logger

  @impl WorkerBehavior
  def handle_work(args) do
    handle_export_work(args)
  end

  defp handle_export_work(%{"source_video_id" => source_video_id}) do
    Logger.info("ExportWorker: Starting export for source_video_id: #{source_video_id}")

    # Get all approved virtual clips for this source video
    virtual_clips = get_approved_virtual_clips(source_video_id)

    case virtual_clips do
      [] ->
        Logger.info(
          "ExportWorker: No approved virtual clips found for source_video_id: #{source_video_id}"
        )

        :ok

      clips ->
        Logger.info("ExportWorker: Found #{length(clips)} approved virtual clips to export")
        process_virtual_clips_batch(clips)
    end
  end

  defp get_approved_virtual_clips(source_video_id) do
    import Ecto.Query

    # IDEMPOTENCY: Only get virtual clips that haven't been exported yet
    query =
      from(c in Clip,
        where:
          c.source_video_id == ^source_video_id and
            c.is_virtual == true and
            c.ingest_state == "review_approved",
        preload: [:source_video]
      )

    Heaters.Repo.all(query)
  end

  defp process_virtual_clips_batch([first_clip | _rest] = clips) do
    source_video = first_clip.source_video

    # Validate that gold master is available
    case source_video.gold_master_filepath do
      nil ->
        error_msg = "No gold master available for source_video_id: #{source_video.id}"
        Logger.error("ExportWorker: #{error_msg}")
        mark_clips_export_failed(clips, error_msg)

      gold_master_path ->
        Logger.info(
          "ExportWorker: Processing #{length(clips)} clips from gold master: #{gold_master_path}"
        )

        execute_batch_export(clips, source_video, gold_master_path)
    end
  end

  defp execute_batch_export(clips, source_video, gold_master_path) do
    # Transition clips to exporting state
    case StateManager.start_export_batch(clips) do
      {:ok, updated_clips} ->
        run_export_task(updated_clips, source_video, gold_master_path)

      {:error, reason} ->
        Logger.error(
          "ExportWorker: Failed to transition clips to exporting state: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp run_export_task(clips, source_video, gold_master_path) do
    # Prepare export arguments for Python task
    export_args = %{
      source_video_id: source_video.id,
      gold_master_path: gold_master_path,
      clips_data: prepare_clips_data(clips),
      video_title: source_video.title
    }

    Logger.info("ExportWorker: Running Python export with #{length(clips)} clips")

    case PyRunner.run("export_clips", export_args, timeout: :timer.minutes(45)) do
      {:ok, %{"status" => "success"} = result} ->
        Logger.info("ExportWorker: Python export completed successfully")
        process_export_results(clips, result)

      {:ok, %{"status" => "error", "error" => error_msg}} ->
        Logger.error("ExportWorker: Python export failed: #{error_msg}")
        mark_clips_export_failed(clips, error_msg)

      {:error, reason} ->
        Logger.error("ExportWorker: PyRunner failed: #{inspect(reason)}")
        mark_clips_export_failed(clips, "PyRunner failed: #{inspect(reason)}")
    end
  end

  defp prepare_clips_data(clips) do
    Enum.map(clips, fn clip ->
      %{
        clip_id: clip.id,
        clip_identifier: clip.clip_identifier,
        cut_points: clip.cut_points
      }
    end)
  end

  defp process_export_results(clips, results) do
    # Extract exported clips data from Python task
    exported_clips = Map.get(results, "exported_clips", [])
    metadata = Map.get(results, "metadata", %{})

    case validate_export_results(clips, exported_clips) do
      :ok ->
        update_clips_to_physical(clips, exported_clips, metadata)

      {:error, reason} ->
        Logger.error("ExportWorker: Export results validation failed: #{reason}")
        mark_clips_export_failed(clips, reason)
    end
  end

  defp validate_export_results(clips, exported_clips) do
    expected_count = length(clips)
    actual_count = length(exported_clips)

    if expected_count == actual_count do
      # Verify all clip IDs are present
      expected_ids = MapSet.new(clips, & &1.id)
      actual_ids = MapSet.new(exported_clips, &Map.get(&1, "clip_id"))

      if MapSet.equal?(expected_ids, actual_ids) do
        :ok
      else
        missing = MapSet.difference(expected_ids, actual_ids) |> MapSet.to_list()
        {:error, "Missing exported clips for IDs: #{inspect(missing)}"}
      end
    else
      {:error, "Expected #{expected_count} exported clips, got #{actual_count}"}
    end
  end

  defp update_clips_to_physical(clips, exported_clips, metadata) do
    # Create a map for quick lookup
    exported_map =
      Map.new(exported_clips, fn clip_data ->
        {Map.get(clip_data, "clip_id"), clip_data}
      end)

    # Update each clip to physical state
    results =
      Enum.map(clips, fn clip ->
        case Map.get(exported_map, clip.id) do
          nil ->
            {:error, "No export data for clip #{clip.id}"}

          export_data ->
            update_single_clip_to_physical(clip, export_data, metadata)
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        Logger.info("ExportWorker: Successfully updated #{length(clips)} clips to physical")
        :ok

      {:error, reason} ->
        Logger.error("ExportWorker: Failed to update clips: #{reason}")
        {:error, reason}
    end
  end

  defp update_single_clip_to_physical(clip, export_data, metadata) do
    clip_filepath = Map.get(export_data, "output_path")
    duration = Map.get(export_data, "duration")

    update_attrs = %{
      is_virtual: false,
      clip_filepath: clip_filepath,
      ingest_state: "exported",
      processing_metadata:
        Map.merge(clip.processing_metadata || %{}, %{
          export_metadata: metadata,
          exported_duration: duration
        })
    }

    case StateManager.complete_export(clip.id, update_attrs) do
      {:ok, updated_clip} ->
        Logger.debug("ExportWorker: Updated clip #{clip.id} to physical: #{clip_filepath}")
        {:ok, updated_clip}

      {:error, reason} ->
        Logger.error("ExportWorker: Failed to update clip #{clip.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp mark_clips_export_failed(clips, reason) do
    Enum.each(clips, fn clip ->
      case StateManager.mark_export_failed(clip.id, reason) do
        {:ok, _} ->
          Logger.debug("ExportWorker: Marked clip #{clip.id} as export_failed")

        {:error, db_error} ->
          Logger.error(
            "ExportWorker: Failed to mark clip #{clip.id} as failed: #{inspect(db_error)}"
          )
      end
    end)

    {:error, reason}
  end
end
