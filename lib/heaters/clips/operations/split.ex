defmodule Heaters.Clips.Operations.Split do
  @moduledoc """
  Video split operations - I/O orchestration layer.

  Splits video clips at specified frame boundaries, creating two separate clips
  when the resulting segments meet minimum duration requirements.

  Uses domain modules for business logic and infrastructure adapters for I/O operations.
  """

  require Logger

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.Operations.Shared.{Types, TempManager, FFmpegRunner}

  # Domain modules (pure business logic)
  alias Heaters.Clips.Operations.Split.{Calculations, Validation, FileNaming}
  alias Heaters.Clips.Operations.Shared.ResultBuilding

  # Infrastructure adapters (I/O operations)
  alias Heaters.Infrastructure.Adapters.{DatabaseAdapter, S3Adapter}

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
    start_time = System.monotonic_time()

    Logger.info("Split: Starting split for clip_id: #{clip_id} at frame: #{split_at_frame}")

    TempManager.with_temp_directory("split", fn temp_dir ->
      with {:ok, clip} <- fetch_clip_data(clip_id),
           :ok <- validate_split_requirements(clip, split_at_frame),
           fps <- extract_video_fps(clip),
           {:ok, split_params} <- build_split_parameters(clip, split_at_frame, fps),
           {:ok, local_video_path} <- download_source_video(clip, temp_dir),
           {:ok, split_segments} <- calculate_split_segments(split_params),
           :ok <- validate_split_viability(split_segments),
           {:ok, created_clips} <-
             create_split_video_files(local_video_path, temp_dir, split_segments, split_params),
           {:ok, uploaded_clips} <- upload_split_clips(created_clips, clip),
           {:ok, cleanup_result} <- cleanup_original_file(clip),
           {:ok, new_clip_records} <- create_clip_records(uploaded_clips, clip),
           :ok <- update_original_clip_state(clip_id) do
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
    Calculations.extract_fps_from_metadata(clip, 30.0)
  end

  @spec build_split_parameters(Clip.t(), integer(), float()) ::
          {:ok, Calculations.split_params()} | {:error, String.t()}
  defp build_split_parameters(clip, split_at_frame, fps) do
    Calculations.build_split_params(clip, split_at_frame, fps)
  end

  @spec download_source_video(Clip.t(), String.t()) :: {:ok, String.t()} | {:error, any()}
  defp download_source_video(clip, temp_dir) do
    local_filename = Path.basename(clip.clip_filepath)
    S3Adapter.download_clip_video(clip, temp_dir, local_filename)
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

    case FFmpegRunner.create_video_clip(source_video_path, output_path, start_time, end_time) do
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

        {:ok, clip_data}

      {:error, reason} ->
        segment_label = if segment_type == :before_split, do: "A", else: "B"
        Logger.error("Split: Failed to create clip #{segment_label}: #{reason}")
        {:error, reason}
    end
  end

  @spec upload_split_clips(list(map()), Clip.t()) :: {:ok, list(map())} | {:error, any()}
  defp upload_split_clips(created_clips, %Clip{source_video_id: source_video_id}) do
    uploaded_clips =
      created_clips
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {clip_data, index}, acc ->
        s3_key = FileNaming.generate_s3_key(source_video_id, clip_data.filename)

        case S3Adapter.upload_file(clip_data.local_path, s3_key, "Split") do
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

    case S3Adapter.delete_file(s3_path) do
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
        # Extract just the clip segment data for processing metadata
        clip_segment = %{
          start_time_seconds: clip_data.start_time_seconds,
          end_time_seconds: clip_data.end_time_seconds,
          start_frame: clip_data.start_frame,
          end_frame: clip_data.end_frame,
          duration_seconds: clip_data.duration_seconds,
          segment_type: clip_data.segment_type
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
end
