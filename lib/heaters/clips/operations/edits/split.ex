defmodule Heaters.Clips.Operations.Edits.Split do
  @moduledoc """
  Video split operations - I/O orchestration layer.

  Splits video clips at specified frame boundaries, creating two separate clips
  when the resulting segments meet minimum duration requirements.

  ## Pure Clip-Relative Approach

  This module implements a pure clip-relative approach for simplicity and efficiency:

  1. **Frontend**: Uses 1-indexed clip-relative frames (1 to total_frames-1)
  2. **Backend Validation**: Validates against clip duration using consistent FPS calculation
  3. **FFmpeg Operations**: Works directly with clip files using clip-relative timestamps
  4. **No Source Downloads**: Avoids downloading multi-gigabyte source videos

  Frame-to-time conversion is done using clip-relative coordinates:
  - `clip_relative_time = (split_frame - 1) / fps`
  - Split validation: `1 < split_frame < clip_total_frames`

  ## Frame Indexing Consistency Fix

  The system now ensures consistent frame calculations between frontend and backend:
  - **FPS Source Priority**: sprite metadata fps → source video fps → processing metadata fps → 30.0 fallback
  - **Calculation Method**: Uses `Float.ceil(duration * fps)` to match sprite sheet logic exactly
  - **Eliminates Errors**: Prevents "Split frame X is outside clip range" errors from FPS mismatches

  ## Idempotent and Transactional Operations

  Split operations are designed for production reliability:
  - **Database-First Approach**: Creates clip records before deleting original files
  - **Conflict Resolution**: Handles unique constraint violations gracefully
  - **Retry Safety**: Detects already-completed splits and handles file-not-found scenarios
  - **State Validation**: Checks for review_archived state and existing split clips

  Uses domain modules for business logic and infrastructure adapters for I/O operations.
  """

  require Logger

  alias Heaters.Clips.Clip
  alias Heaters.Clips.Operations.Shared.{Types, TempManager, FFmpegRunner}
  alias Heaters.Utils

  # Domain modules (pure business logic)
  alias Heaters.Clips.Operations.Edits.Split.{Calculations, Validation, FileNaming}
  alias Heaters.Clips.Operations.Shared.ResultBuilding

  # Infrastructure adapters (I/O operations)
  alias Heaters.Infrastructure.{S3, Adapters.DatabaseAdapter, Adapters.S3Adapter}

  @doc """
  Splits a clip at the specified frame, creating two separate clips.

  ## Frame Number Convention: CLIP-RELATIVE FRAMES

  **CRITICAL**: The `split_at_frame` parameter MUST be a clip-relative frame number
  (1-indexed), NOT an absolute source video frame number.

  - Frame validation: `1 < split_at_frame < clip_total_frames`
  - Both resulting segments must meet minimum duration requirements
  - Split frame cannot be at frame 1 or last frame (would create zero-duration segments)

  ## Operation Flow

  1. **Idempotency Check**: Detects if split already completed (clips exist or archived)
  2. **Validation**: Validates clip state, file existence, and frame bounds
  3. **Video Processing**: Downloads clip, creates split segments, uploads to S3
  4. **Database Operations**: Creates new clip records with conflict handling
  5. **Cleanup**: Deletes original clip file and updates state to review_archived

  ## Reliability Features

  - **Database-First**: Creates records before irreversible S3 deletion
  - **Conflict Resolution**: Handles duplicate `clip_filepath` entries gracefully
  - **Retry Safety**: Detects already-processed operations and file-not-found scenarios
  - **Frame Consistency**: Uses same FPS calculation as sprite metadata for validation

  ## Parameters
  - `clip_id`: ID of the clip to split
  - `split_at_frame`: Clip-relative frame number (1-indexed) where to split

  ## Returns
  - `{:ok, %SplitResult{}}` on success with new clip IDs and metadata
  - `{:error, :already_processed}` if split already completed (idempotent)
  - `{:error, reason}` on validation or processing errors

  ## Examples

      # Split clip 123 at frame 50 (clip-relative)
      {:ok, result} = Split.run_split(123, 50)
      result.new_clip_ids
      # => [124, 125]

      # Already processed - idempotent behavior
      {:error, :already_processed} = Split.run_split(123, 50)
  """
  @spec run_split(integer(), integer()) :: {:ok, Types.SplitResult.t()} | {:error, any()}
  def run_split(clip_id, split_at_frame) do
    start_time = System.monotonic_time()

    Logger.info("Split: Starting split for clip_id: #{clip_id} at frame: #{split_at_frame}")

    TempManager.with_temp_directory("split", fn temp_dir ->
      with {:ok, clip} <- fetch_clip_data(clip_id),
           :ok <- check_split_idempotency(clip, split_at_frame),
           :ok <- validate_split_requirements(clip, split_at_frame),
           fps <- extract_video_fps(clip),
           {:ok, split_params} <- build_split_parameters(clip, split_at_frame, fps),
           {:ok, local_video_path} <- download_source_video(clip, temp_dir),
           {:ok, split_segments} <- calculate_split_segments(split_params),
           :ok <- validate_split_viability(split_segments),
           {:ok, created_clips} <-
             create_split_video_files(local_video_path, temp_dir, split_segments, split_params),
           {:ok, uploaded_clips} <- upload_split_clips(created_clips, clip),
           # CRITICAL FIX: Database operations BEFORE irreversible cleanup
           {:ok, new_clip_records} <- create_clip_records(uploaded_clips, clip),
           :ok <- update_original_clip_state(clip_id),
           # Now safe to cleanup original file after database success
           {:ok, cleanup_result} <- cleanup_original_file(clip) do
        duration_ms = calculate_duration(start_time)

        result =
          build_success_result(
            clip_id,
            new_clip_records,
            uploaded_clips,
            cleanup_result,
            split_at_frame,
            duration_ms
          )

        Logger.info("Split: Successfully completed split for clip_id: #{clip_id}")
        {:ok, result}
      else
        error ->
          Logger.error("Split: Failed to split clip_id: #{clip_id}, error: #{inspect(error)}")
          error
      end
    end)
  end

  ## Private functions - I/O orchestration using Domain and Infrastructure layers

  @spec fetch_clip_data(integer()) :: {:ok, Clip.t()} | {:error, any()}
  defp fetch_clip_data(clip_id) do
    DatabaseAdapter.get_clip_with_artifacts(clip_id)
  end

  @spec validate_split_requirements(Clip.t(), integer()) :: :ok | {:error, String.t()}
  defp validate_split_requirements(clip, split_at_frame) do
    Validation.validate_split_requirements(clip, split_at_frame)
  end

  @spec extract_video_fps(Clip.t()) :: float()
  defp extract_video_fps(clip) do
    # Use the same consistent FPS calculation as validation and calculations modules
    # This ensures all split operations use identical frame counting logic
    Calculations.extract_consistent_fps(clip)
  end

  @spec build_split_parameters(Clip.t(), integer(), float()) ::
          {:ok, Calculations.split_params()} | {:error, String.t()}
  defp build_split_parameters(clip, split_at_frame, fps) do
    Calculations.build_split_params(clip, split_at_frame, fps)
  end

  @spec download_source_video(Clip.t(), String.t()) :: {:ok, String.t()} | {:error, any()}
  defp download_source_video(clip, temp_dir) do
    # Download the clip file for efficient extraction
    # Note: Domain logic calculates absolute timestamps, then converts to clip-relative
    local_filename = Path.basename(clip.clip_filepath)

    case S3Adapter.download_clip_video(clip, temp_dir, local_filename) do
      {:ok, local_path} ->
        {:ok, local_path}

      {:error, error_string} when is_binary(error_string) ->
        # S3.download_file returns string errors, check if it's a 404-type error
        if String.contains?(error_string, "404") or String.contains?(error_string, "not found") do
          Logger.error("Split: Original clip file not found in S3: #{clip.clip_filepath}")
          Logger.error("Split: This may indicate the file was already deleted by a previous split operation")
          {:error, "Original clip file not found - may have been deleted by previous operation"}
        else
          Logger.error("Split: Failed to download clip file: #{error_string}")
          {:error, error_string}
        end
    end
  end

  @spec calculate_split_segments(Calculations.split_params()) ::
          {:ok, {Calculations.clip_segment() | nil, Calculations.clip_segment() | nil}}
          | {:error, String.t()}
  defp calculate_split_segments(split_params) do
    Calculations.calculate_split_segments(split_params)
  end

  @spec validate_split_viability(
          {Calculations.clip_segment() | nil, Calculations.clip_segment() | nil}
        ) :: :ok | {:error, String.t()}
  defp validate_split_viability(split_segments) do
    Calculations.validate_split_viability(split_segments)
  end

  @spec create_split_video_files(
          String.t(),
          String.t(),
          {Calculations.clip_segment() | nil, Calculations.clip_segment() | nil},
          Calculations.split_params()
        ) :: {:ok, list(map())} | {:error, any()}
  defp create_split_video_files(
         source_video_path,
         output_dir,
         {segment_a, segment_b},
         split_params
       ) do
    source_title = split_params.source_title

    with {:ok, clip_a_data} <-
           create_clip_from_segment(source_video_path, output_dir, source_title, segment_a),
         {:ok, clip_b_data} <-
           create_clip_from_segment(source_video_path, output_dir, source_title, segment_b) do
      # Filter out nil results
      created_clips = [clip_a_data, clip_b_data] |> Enum.filter(& &1)

      case Validation.validate_clips_created(created_clips) do
        :ok -> {:ok, created_clips}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec create_clip_from_segment(
          String.t(),
          String.t(),
          String.t(),
          Calculations.clip_segment() | nil
        ) :: {:ok, map() | nil} | {:error, any()}
  defp create_clip_from_segment(_source_video_path, _output_dir, _source_title, nil) do
    {:ok, nil}
  end

  defp create_clip_from_segment(source_video_path, output_dir, source_title, clip_segment) do
    %{
      start_time_seconds: start_time,
      end_time_seconds: end_time,
      duration_seconds: duration,
      segment_type: segment_type
    } = clip_segment

    filename = FileNaming.generate_split_filename(source_title, clip_segment)
    clip_identifier = FileNaming.generate_clip_identifier(source_title, clip_segment)
    output_path = Path.join(output_dir, filename)

    Logger.debug(
      "Split: Creating video clip #{filename} with start_time=#{start_time}, end_time=#{end_time}, duration=#{duration}"
    )

    # Validate time ranges before calling FFmpeg
    cond do
      start_time >= end_time ->
        Logger.error(
          "Split: Invalid time range for #{filename}: start_time=#{start_time} >= end_time=#{end_time}"
        )

        {:error, "Invalid time range: start_time must be less than end_time"}

      start_time < 0 ->
        Logger.error("Split: Invalid start_time for #{filename}: start_time=#{start_time} < 0")

        {:error, "Invalid start_time: must be non-negative"}

      duration <= 0 ->
        Logger.error("Split: Invalid duration for #{filename}: duration=#{duration} <= 0")

        {:error, "Invalid duration: must be positive"}

      true ->
        # Use clip-relative coordinates for efficient FFmpeg extraction from clip file
        case FFmpegRunner.create_video_clip(
               source_video_path,
               output_path,
               clip_segment.clip_relative_start,
               clip_segment.clip_relative_end
             ) do
          {:ok, file_size} ->
            clip_data =
              Map.merge(clip_segment, %{
                clip_identifier: clip_identifier,
                filename: filename,
                local_path: output_path,
                file_size: file_size
              })

            segment_label = if segment_type == :before_split, do: "A", else: "B"

            Logger.info(
              "Split: Created clip #{segment_label}: #{filename} (#{Float.round(duration, 2)}s)"
            )

            # Validate the created file has video streams
            case validate_created_video_file(output_path) do
              :ok ->
                {:ok, clip_data}

              {:error, reason} ->
                Logger.error("Split: Created file #{filename} failed validation: #{reason}")

                {:error, "Created video file is invalid: #{reason}"}
            end

          {:error, reason} ->
            segment_label = if segment_type == :before_split, do: "A", else: "B"
            Logger.error("Split: Failed to create clip #{segment_label}: #{reason}")
            {:error, reason}
        end
    end
  end

  @spec validate_created_video_file(String.t()) :: :ok | {:error, String.t()}
  defp validate_created_video_file(file_path) do
    case FFmpegRunner.get_video_metadata(file_path) do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        {:error, "ffprobe validation failed: #{inspect(reason)}"}
    end
  end

  @spec upload_split_clips(list(map()), Clip.t()) :: {:ok, list(map())} | {:error, any()}
  defp upload_split_clips(created_clips, %Clip{} = clip) do
    source_title = get_source_title(clip)

    uploaded_clips =
      created_clips
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {clip_data, index}, acc ->
        s3_key = FileNaming.generate_s3_key(source_title, clip_data.filename)

        case S3.upload_file_with_operation(clip_data.local_path, s3_key, "Split") do
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

    case S3.delete_file(s3_path) do
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
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    clips_attrs =
      Enum.map(uploaded_clips, fn clip_data ->
        # Extract just the clip segment data for processing metadata
        clip_segment = %{
          start_time_seconds: clip_data.start_time_seconds,
          end_time_seconds: clip_data.end_time_seconds,
          start_frame: clip_data.start_frame,
          end_frame: clip_data.end_frame,
          duration_seconds: clip_data.duration_seconds,
          segment_type: clip_data.segment_type,
          clip_relative_start: clip_data.clip_relative_start,
          clip_relative_end: clip_data.clip_relative_end
        }

        processing_metadata =
          FileNaming.generate_processing_metadata(
            clip_segment,
            original_clip.id,
            clip_data.file_size
          )

        %{
          clip_filepath: "/#{clip_data.s3_key}",
          clip_identifier: clip_data.clip_identifier,
          start_frame: clip_data.start_frame,
          end_frame: clip_data.end_frame,
          start_time_seconds: clip_data.start_time_seconds,
          end_time_seconds: clip_data.end_time_seconds,
          ingest_state: "spliced",
          source_video_id: original_clip.source_video_id,
          processing_metadata: processing_metadata,
          inserted_at: now,
          updated_at: now
        }
      end)

    # Use database-level idempotency to handle duplicate clip_filepath gracefully
    case DatabaseAdapter.create_clips_with_conflict_handling(clips_attrs) do
      {:ok, clips} when clips != [] ->
        Logger.info("Split: Created #{length(clips)} new clip records")
        {:ok, clips}

      {:ok, []} ->
        # All clips already existed, fetch them instead
        Logger.info("Split: All split clips already exist, fetching existing records")
        fetch_existing_clips_by_identifiers(clips_attrs)

      {:error, reason} ->
        Logger.error("Split: Error creating clip records: #{reason}")
        {:error, reason}
    end
  end

  @spec fetch_existing_clips_by_identifiers(list(map())) :: {:ok, list(Clip.t())} | {:error, any()}
  defp fetch_existing_clips_by_identifiers(clips_attrs) do
    identifiers = Enum.map(clips_attrs, & &1.clip_identifier)

    case DatabaseAdapter.get_clips_by_identifiers(identifiers) do
      {:ok, clips} ->
        Logger.info("Split: Fetched #{length(clips)} existing split clips")
        {:ok, clips}

      {:error, reason} ->
        Logger.error("Split: Failed to fetch existing clips: #{inspect(reason)}")
        {:error, "Failed to fetch existing clips: #{inspect(reason)}"}
    end
  end

  @spec update_original_clip_state(integer()) :: :ok | {:error, any()}
  defp update_original_clip_state(clip_id) do
    with {:ok, clip} <- DatabaseAdapter.get_clip(clip_id),
         {:ok, _updated_clip} <-
           DatabaseAdapter.update_clip(clip, %{ingest_state: "review_archived"}) do
      Logger.info("Split: Updated original clip #{clip_id} to review_archived state")
      :ok
    else
      {:error, reason} ->
        Logger.error("Split: Failed to update original clip state: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec build_success_result(integer(), list(Clip.t()), list(map()), map(), integer(), integer()) ::
          Types.SplitResult.t()
  defp build_success_result(
         original_clip_id,
         new_clip_records,
         uploaded_clips,
         cleanup_result,
         split_at_frame,
         duration_ms
       ) do
    new_clip_ids = Enum.map(new_clip_records, & &1.id)

    split_metadata = %{
      split_at_frame: split_at_frame,
      clips_created: length(new_clip_records),
      total_duration: Enum.reduce(uploaded_clips, 0.0, &(&1.duration_seconds + &2))
    }

    ResultBuilding.build_split_result_with_details(
      original_clip_id,
      new_clip_ids,
      uploaded_clips,
      cleanup_result,
      split_metadata,
      duration_ms
    )
  end

  @spec calculate_duration(integer()) :: integer()
  defp calculate_duration(start_time) do
    System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
  end

  @spec get_source_title(Clip.t()) :: String.t()
  defp get_source_title(%Clip{source_video: %{title: title}}) when not is_nil(title) do
    title
  end

  defp get_source_title(%Clip{source_video_id: source_video_id}) do
    # Use the same database lookup pattern as clip_artifacts for consistency
    alias Heaters.Videos.Queries, as: VideoQueries

    case VideoQueries.get_source_video(source_video_id) do
      {:ok, source_video} ->
        source_video.title

      {:error, _} ->
        # Fallback to ID-based structure if title lookup fails (consistent with clip_artifacts)
        "video_#{source_video_id}"
    end
  end

  @spec check_split_idempotency(Clip.t(), integer()) :: :ok | {:error, String.t()}
  defp check_split_idempotency(clip, split_at_frame) do
    case clip.ingest_state do
      "review_archived" ->
        Logger.info("Split: Clip #{clip.id} already split (review_archived state), operation is idempotent")
        {:error, :already_processed}

      _ ->
        # Check if split clips already exist in database
        case check_existing_split_clips(clip, split_at_frame) do
          {:ok, :no_existing_clips} ->
            :ok

          {:ok, :existing_clips_found} ->
            Logger.info("Split: Found existing split clips for clip_id: #{clip.id}, frame: #{split_at_frame}")
            {:error, :already_processed}

          {:error, reason} ->
            Logger.warning("Split: Error checking existing clips: #{inspect(reason)}")
            :ok  # Continue with split operation if check fails
        end
    end
  end

  @spec check_existing_split_clips(Clip.t(), integer()) :: {:ok, :no_existing_clips | :existing_clips_found} | {:error, any()}
  defp check_existing_split_clips(clip, split_at_frame) do
    # Generate expected clip identifiers for this split operation
    fps = extract_video_fps(clip)
    clip_duration_seconds = clip.end_time_seconds - clip.start_time_seconds
    total_frames = Float.ceil(clip_duration_seconds * fps) |> trunc()

    source_title = get_source_title(clip)

    # Expected identifiers for split segments
    before_identifier = "#{Utils.sanitize_filename(source_title)}_1_#{split_at_frame - 1}"
    after_identifier = "#{Utils.sanitize_filename(source_title)}_#{split_at_frame}_#{total_frames}"

    case DatabaseAdapter.check_clips_exist_by_identifiers([before_identifier, after_identifier]) do
      {:ok, existing_count} when existing_count > 0 ->
        {:ok, :existing_clips_found}

      {:ok, 0} ->
        {:ok, :no_existing_clips}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
