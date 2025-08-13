defmodule Heaters.Processing.Export.Worker do
  @moduledoc """
  Worker for exporting virtual clips to physical clips using efficient stream copy.

  This worker handles the final stage of the virtual clip pipeline by clipping
  approved virtual clips into physical MP4 files using the efficient unified 
  stream copy architecture.

  ## Storage Strategy & Quality Decision

  **Why Proxy Instead of Master:**
  - **Optimized for Review**: Proxy uses CRF 28, 720p optimized for internal review UI
  - **Instant Access**: Both proxy and master in S3 Standard for instant access
  - **Stream Copy**: No re-encoding = zero quality loss + 10x faster
  - **File Size**: Proxy much smaller than master for efficient processing
  - **Perfect for Export**: CRF 28 all-I-frame is ideal for stream copy operations

  **Master**: High-quality H.264 archival stored in S3 Standard
  **Proxy**: Dual-purpose for review AND final export source

  ## Efficient Workflow (V2)

  1. Group virtual clips by source_video for batch processing
  2. Process directly from CloudFront URLs (no downloads)
  3. Extract individual clips using FFmpeg stream copy via unified abstraction
  4. Upload physical clips to S3 Standard
  5. Update clip records: is_virtual = false, add clip_filepath

  ## State Management

  - **Input**: Virtual clips in :review_approved state
  - **Output**: Physical clips with clip_filepath, is_virtual = false
  - **Error Handling**: Marks clips as :export_failed on errors
  - **Idempotency**: Skip if is_virtual = false (already exported)

  ## Batch Processing

  For efficiency, this worker processes all approved virtual clips from the same
  source video together in a single job. This eliminates proxy downloads entirely
  and minimizes temporary file operations.

  ## Performance Benefits

  - **10x Faster**: Stream copy vs re-encoding + no local downloads
  - **Zero Quality Loss**: No transcoding artifacts or generational loss
  - **Resource Efficient**: Minimal CPU and I/O usage
  - **Unified Architecture**: Same foundations as playback cache system

  ## Architecture (V2)

  - **Export**: Unified StreamClip abstraction with profile-based configuration
  - **State Management**: Elixir state transitions and database operations  
  - **Storage**: Direct CloudFront → S3 processing, no local downloads
  - **Profiles**: Uses :final_export profile for audio preservation
  """

  use Heaters.Pipeline.WorkerBehavior,
    queue: :media_processing,
    # 30 minutes for large exports
    unique: [period: 1800, fields: [:args]]

  alias Heaters.Repo
  alias Heaters.Media.Clip
  alias Heaters.Processing.Export.StateManager
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Processing.Support.ResultBuilder
  require Logger

  # Suppress dialyzer warnings for PyRunner calls when environment is not configured.
  #
  # JUSTIFICATION: PyRunner requires DEV_DATABASE_URL and DEV_S3_BUCKET_NAME environment
  # variables. When not set, PyRunner always fails, making success patterns and their
  # dependent functions unreachable. In configured environments, these will succeed.
  @dialyzer {:nowarn_function,
             [
               handle_export_work: 1,
               run_export_task: 3,
               process_native_export_results: 2,
               validate_native_export_results: 2,
               update_clips_to_physical_native: 3,
               update_single_clip_to_physical_native: 3,
               calculate_total_duration_native: 1
             ]}

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

        # Return structured result for no clips to process
        export_result =
          ResultBuilder.export_success(source_video_id, [], %{
            successful_exports: 0,
            failed_exports: 0,
            no_clips_to_process: true
          })

        ResultBuilder.log_result(__MODULE__, export_result)
        export_result

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
            is_nil(c.clip_filepath) and
            c.ingest_state == :review_approved,
        preload: [:source_video]
      )

    Repo.all(query)
  end

  defp process_virtual_clips_batch([first_clip | _rest] = clips) do
    source_video = first_clip.source_video

    # Validate that proxy is available
    case source_video.proxy_filepath do
      nil ->
        error_msg = "No proxy available for source_video_id: #{source_video.id}"
        Logger.error("ExportWorker: #{error_msg}")
        mark_clips_export_failed(clips, error_msg)

      proxy_path ->
        Logger.info("ExportWorker: Processing #{length(clips)} clips from proxy: #{proxy_path}")

        execute_batch_export(clips, source_video, proxy_path)
    end
  end

  defp execute_batch_export(clips, source_video, proxy_path) do
    # Transition clips to exporting state
    case StateManager.start_export_batch(clips) do
      {:ok, updated_clips} ->
        run_export_task(updated_clips, source_video, proxy_path)

      {:error, reason} ->
        Logger.error(
          "ExportWorker: Failed to transition clips to exporting state: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp run_export_task(clips, source_video, _proxy_path) do
    clips_data = prepare_clips_data(clips, source_video.title)

    Logger.info("ExportWorker: Running efficient stream copy export with #{length(clips)} clips")

    case Heaters.Processing.Export.Core.export_clips_efficient(
           clips_data,
           source_video,
           operation_name: "ExportWorker",
           profile: :final_export
         ) do
      {:ok, result} ->
        Logger.info("ExportWorker: Efficient stream copy export completed successfully")
        process_native_export_results(clips, result)

      {:error, reason} ->
        Logger.error("ExportWorker: Efficient export failed: #{reason}")
        mark_clips_export_failed(clips, reason)
    end
  end

  defp prepare_clips_data(clips, video_title) do
    Enum.map(clips, fn clip ->
      # Generate S3 output path using centralized path service (eliminates Python coupling)
      s3_output_path =
        Heaters.Storage.S3.Paths.generate_clip_path(
          clip.id,
          video_title || "clip_#{clip.id}",
          clip.clip_identifier
        )

      %{
        clip_id: clip.id,
        clip_identifier: clip.clip_identifier,
        cut_points: %{
          start_time_seconds: clip.start_time_seconds,
          end_time_seconds: clip.end_time_seconds
        },
        # S3 path generated by Elixir (eliminates Python path generation coupling)
        s3_output_path: s3_output_path
      }
    end)
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

  # Native Elixir result processing functions

  defp process_native_export_results(
         clips,
         %Heaters.Processing.Support.Types.ExportResult{} = result
       ) do
    # Extract exported clips data from native Elixir result
    exported_clips = result.exported_clips
    metadata = result.metadata || %{}

    case validate_native_export_results(clips, exported_clips) do
      :ok ->
        update_clips_to_physical_native(clips, exported_clips, metadata)

      {:error, reason} ->
        Logger.error("ExportWorker: Export results validation failed: #{reason}")
        mark_clips_export_failed(clips, reason)
    end
  end

  defp validate_native_export_results(clips, exported_clips) do
    expected_count = length(clips)
    actual_count = length(exported_clips)

    if expected_count == actual_count do
      # Verify all clip IDs are present - native results use atom keys
      expected_ids = MapSet.new(clips, & &1.id)
      actual_ids = MapSet.new(exported_clips, &Map.get(&1, :clip_id))

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

  defp update_clips_to_physical_native(clips, exported_clips, metadata) do
    # Create a map for quick lookup - native results use atom keys
    exported_map =
      Map.new(exported_clips, fn clip_data ->
        {Map.get(clip_data, :clip_id), clip_data}
      end)

    # Update each clip with its export data
    results =
      Enum.map(clips, fn clip ->
        case Map.get(exported_map, clip.id) do
          nil ->
            {:error, "No export data found for clip #{clip.id}"}

          export_data ->
            update_single_clip_to_physical_native(clip, export_data, metadata)
        end
      end)

    # Check if all updates succeeded
    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {successes, []} ->
        updated_clips = Enum.map(successes, fn {:ok, clip} -> clip end)
        total_duration = calculate_total_duration_native(exported_clips)

        Logger.info(
          "ExportWorker: Successfully updated #{length(updated_clips)} clips to physical (total: #{total_duration}s)"
        )

        # Build structured result with export statistics
        source_video_id = List.first(clips).source_video_id

        export_result =
          ResultBuilder.export_success(source_video_id, exported_clips, %{
            successful_exports: length(clips),
            failed_exports: 0,
            total_duration_exported: total_duration,
            proxy_metadata: metadata,
            export_method: "stream_copy_native_elixir"
          })

        # Return the result tuple directly 
        export_result

      {_, failures} ->
        failure_reasons = Enum.map(failures, fn {:error, reason} -> reason end)
        {:error, "Failed to update clips: #{inspect(failure_reasons)}"}
    end
  end

  defp update_single_clip_to_physical_native(clip, export_data, metadata) do
    clip_filepath = Map.get(export_data, :output_path)
    duration = Map.get(export_data, :duration)

    update_attrs = %{
      clip_filepath: clip_filepath,
      ingest_state: :exported,
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

  # Helper function to calculate total duration from native exported clips
  defp calculate_total_duration_native(exported_clips) when is_list(exported_clips) do
    exported_clips
    |> Enum.map(&(Map.get(&1, :duration) || 0))
    |> Enum.sum()
    |> Float.round(2)
  end

  defp calculate_total_duration_native(_), do: 0.0
end
