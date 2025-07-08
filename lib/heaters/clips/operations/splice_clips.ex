defmodule Heaters.Clips.Operations.SpliceClips do
  @moduledoc """
  Clip creation and management for splice workflow results.

  This module handles creating clips from splice operation results,
  extracted from the general Ingest module to maintain clear separation of concerns.

  ## Responsibilities
  - Validate clip data structure
  - Bulk insert clips with proper attributes
  - Handle clip creation errors gracefully
  - Generate consistent clip identifiers
  """

  import Ecto.Query
  alias Heaters.Repo
  alias Heaters.Clips.Clip
  require Logger

  @doc """
  Create clips from splice operation results.

  ## Parameters
  - `source_video_id`: ID of the source video these clips belong to
  - `clips_data`: List of maps with clip information

  ## Required fields in clips_data
  - `:clip_filepath` - S3 path to the clip file
  - `:start_time_seconds` - Clip start time in seconds
  - `:end_time_seconds` - Clip end time in seconds

  ## Optional fields in clips_data
  - `:clip_identifier` - Custom identifier (auto-generated if not provided)
  - `:start_frame` - Start frame number
  - `:end_frame` - End frame number

  ## Returns
  - `{:ok, clips}` - List of created Clip structs
  - `{:error, reason}` - Error message if creation fails

  ## Examples

      clips_data = [
        %{
          clip_filepath: "clips/video1/clip_001.mp4",
          start_time_seconds: 0.0,
          end_time_seconds: 5.0,
          start_frame: 0,
          end_frame: 150
        }
      ]

      {:ok, clips} = SpliceClips.create_clips_from_splice(123, clips_data)
  """
  @spec create_clips_from_splice(integer(), list(map())) ::
          {:ok, list(Clip.t())} | {:error, any()}
  def create_clips_from_splice(source_video_id, clips_data) when is_list(clips_data) do
    Logger.info(
      "SpliceClips: Creating #{length(clips_data)} clips for source_video_id: #{source_video_id}"
    )

    with :ok <- validate_clips_data(clips_data) do
      clips_attrs =
        clips_data
        |> Enum.with_index()
        |> Enum.map(fn {clip_data, index} ->
          build_clip_attrs(source_video_id, clip_data, index)
        end)

      # Check for existing clips to make this operation idempotent
      clip_filepaths = Enum.map(clips_attrs, & &1.clip_filepath)

      existing_clips =
        from(c in Clip, where: c.clip_filepath in ^clip_filepaths)
        |> Repo.all()

      existing_filepaths = MapSet.new(existing_clips, & &1.clip_filepath)

      # Filter out clips that already exist
      new_clips_attrs =
        Enum.filter(clips_attrs, fn attrs ->
          not MapSet.member?(existing_filepaths, attrs.clip_filepath)
        end)

      case {length(existing_clips), length(new_clips_attrs)} do
        {existing_count, 0} when existing_count > 0 ->
          Logger.info(
            "SpliceClips: All #{existing_count} clips already exist for source_video_id: #{source_video_id}, skipping creation"
          )

          {:ok, existing_clips}

        {existing_count, new_count} when new_count > 0 ->
          case Repo.insert_all(Clip, new_clips_attrs, returning: true) do
            {^new_count, new_clips} ->
              all_clips = existing_clips ++ new_clips

              Logger.info(
                "SpliceClips: Found #{existing_count} existing clips, created #{new_count} new clips for source_video_id: #{source_video_id}"
              )

              {:ok, all_clips}

            {0, _} ->
              Logger.error(
                "SpliceClips: Failed to create new clips for source_video_id: #{source_video_id}"
              )

              {:error, "Failed to create new clips"}

            {created_count, new_clips} ->
              # Partial success - some clips created but not all
              all_clips = existing_clips ++ new_clips

              Logger.warning(
                "SpliceClips: Expected #{new_count} new clips but created #{created_count} for source_video_id: #{source_video_id}"
              )

              {:ok, all_clips}
          end

        {0, 0} ->
          Logger.error("SpliceClips: No clips to create for source_video_id: #{source_video_id}")
          {:error, "No clips to create"}
      end
    end
  rescue
    e ->
      Logger.error(
        "SpliceClips: Error creating clips for source_video_id #{source_video_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  @doc """
  Validate that clips data has required fields.

  ## Parameters
  - `clips_data`: List of clip data maps to validate

  ## Returns
  - `:ok` if all clips have required fields
  - `{:error, message}` if validation fails

  ## Examples

      clips_data = [%{clip_filepath: "path.mp4", start_time_seconds: 0.0, end_time_seconds: 5.0}]
      :ok = SpliceClips.validate_clips_data(clips_data)
  """
  @spec validate_clips_data(list(map())) :: :ok | {:error, String.t()}
  def validate_clips_data(clips_data) when is_list(clips_data) do
    required_fields = [:clip_filepath, :start_time_seconds, :end_time_seconds]

    invalid_clips =
      clips_data
      |> Enum.with_index()
      |> Enum.filter(fn {clip_data, _index} ->
        not Enum.all?(required_fields, &Map.has_key?(clip_data, &1))
      end)

    if Enum.empty?(invalid_clips) do
      :ok
    else
      invalid_indices = Enum.map(invalid_clips, fn {_clip_data, index} -> index end)

      {:error,
       "Clips at indices #{inspect(invalid_indices)} are missing required fields: #{inspect(required_fields)}"}
    end
  end

  # Private helper functions

  defp build_clip_attrs(source_video_id, clip_data, index) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Generate clip_identifier if not provided
    clip_identifier =
      Map.get(clip_data, :clip_identifier) ||
        "#{source_video_id}_clip_#{String.pad_leading(to_string(index + 1), 3, "0")}"

    %{
      source_video_id: source_video_id,
      clip_filepath: Map.fetch!(clip_data, :clip_filepath),
      clip_identifier: clip_identifier,
      start_frame: Map.get(clip_data, :start_frame),
      end_frame: Map.get(clip_data, :end_frame),
      start_time_seconds: Map.fetch!(clip_data, :start_time_seconds),
      end_time_seconds: Map.fetch!(clip_data, :end_time_seconds),
      # Set initial state for splice-created clips
      ingest_state: "spliced",
      inserted_at: now,
      updated_at: now
    }
  end
end
