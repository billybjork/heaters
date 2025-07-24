defmodule Heaters.Clips.VirtualClips do
  @moduledoc """
  Operations for creating and managing virtual clips.

  Virtual clips are database records with cut points but no physical files.
  They enable instant merge/split operations during review and are only
  encoded to physical files during the final export stage.

  ## Virtual vs Physical Clips

  - **Virtual clips**: Database records with cut_points JSON, no clip_filepath
  - **Physical clips**: Database records with clip_filepath, created during export
  - **Transition**: Virtual clips become physical via export worker

  ## Cut Points Format

  Cut points are stored as JSON with both frame and time information:
  ```json
  {
    "start_frame": 0,
    "end_frame": 150,
    "start_time_seconds": 0.0,
    "end_time_seconds": 5.0
  }
  ```

  ## Architecture

  - **Creation**: From scene detection cut points
  - **Validation**: Ensures cut points are valid and non-overlapping
  - **State**: Virtual clips start in "pending_review" state
  - **Review**: Same review workflow as physical clips
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Clips.Clip
  require Logger

  # Schema for cut point operations audit trail
  defmodule CutPointOperation do
    use Heaters.Schema

    schema "cut_point_operations" do
      field(:operation_type, :string)
      field(:frame_number, :integer)
      field(:old_frame_number, :integer)
      field(:user_id, :integer)
      field(:affected_clip_ids, {:array, :integer})
      field(:metadata, :map)

      belongs_to(:source_video, Heaters.Videos.SourceVideo)

      timestamps(type: :utc_datetime)
    end

    def changeset(operation, attrs) do
      operation
      |> cast(attrs, [:source_video_id, :operation_type, :frame_number, :old_frame_number,
                      :user_id, :affected_clip_ids, :metadata])
      |> validate_required([:source_video_id, :operation_type, :frame_number, :user_id])
      |> validate_inclusion(:operation_type, ["add", "remove", "move"])
    end
  end

  @doc """
  Create virtual clip records from scene detection cut points.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `cut_points`: List of cut point maps from scene detection
  - `metadata`: Additional metadata from scene detection

  ## Returns
  - `{:ok, clips}` on successful creation
  - `{:error, reason}` on validation or creation failure

  ## Examples

      cut_points = [
        %{"start_frame" => 0, "end_frame" => 150, "start_time_seconds" => 0.0, "end_time_seconds" => 5.0},
        %{"start_frame" => 150, "end_frame" => 300, "start_time_seconds" => 5.0, "end_time_seconds" => 10.0}
      ]

      {:ok, clips} = VirtualClips.create_virtual_clips_from_cut_points(123, cut_points, %{})
  """
  @spec create_virtual_clips_from_cut_points(integer(), list(), map()) ::
          {:ok, list(Clip.t())} | {:error, any()}
  def create_virtual_clips_from_cut_points(source_video_id, cut_points, metadata \\ %{}) do
    Logger.info(
      "VirtualClips: Creating #{length(cut_points)} virtual clips for source_video_id: #{source_video_id}"
    )

    # IDEMPOTENCY: Check if virtual clips already exist for this source video
    case get_existing_virtual_clips(source_video_id) do
      [] ->
        # No existing clips, create new ones
        case validate_cut_points(cut_points) do
          :ok ->
            create_clips_from_validated_cut_points(source_video_id, cut_points, metadata)

          {:error, reason} ->
            Logger.error("VirtualClips: Cut points validation failed: #{reason}")
            {:error, reason}
        end

      existing_clips ->
        # Virtual clips already exist, return them
        Logger.info(
          "VirtualClips: Found #{length(existing_clips)} existing virtual clips for source_video_id: #{source_video_id}"
        )

        {:ok, existing_clips}
    end
  end

  @doc """
  Update virtual clip cut points (used for merge/split operations).

  ## Parameters
  - `clip_id`: ID of the virtual clip to update
  - `new_cut_points`: Updated cut points map

  ## Returns
  - `{:ok, clip}` on successful update
  - `{:error, reason}` on validation or update failure
  """
  @spec update_virtual_clip_cut_points(integer(), map()) :: {:ok, Clip.t()} | {:error, any()}
  def update_virtual_clip_cut_points(clip_id, new_cut_points) do
    case Repo.get(Clip, clip_id) do
      nil ->
        {:error, :not_found}

      %Clip{is_virtual: false} = clip ->
        {:error, "Cannot update cut points for physical clip #{clip.id}"}

      %Clip{is_virtual: true} = clip ->
        case validate_single_cut_point(new_cut_points) do
          :ok ->
            clip
            |> Clip.changeset(%{cut_points: new_cut_points})
            |> Repo.update()

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Add a cut point within a virtual clip, splitting it into two clips.

  This operation finds the virtual clip containing the specified frame,
  splits it at that frame, archives the original clip, and creates two
  new virtual clips to maintain MECE properties.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `frame_number`: Frame number where to add the cut point
  - `user_id`: ID of the user performing the operation

  ## Returns
  - `{:ok, {first_clip, second_clip}}` on successful split
  - `{:error, reason}` on validation or operation failure
  """
  @spec add_cut_point(integer(), integer(), integer()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, any()}
  def add_cut_point(source_video_id, frame_number, user_id) do
    Repo.transaction(fn ->
      # 1. Find virtual clip that contains this frame
      case find_virtual_clip_containing_frame(source_video_id, frame_number) do
        {:ok, target_clip} ->
          # 2. Validate frame is not at clip boundaries (no-op)
          case validate_split_frame(target_clip, frame_number) do
            :ok ->
              # 3. Create two new virtual clips from split
              {first_cut_points, second_cut_points} =
                split_cut_points_at_frame(target_clip.cut_points, frame_number)

              # 4. Create new clips and archive original
              create_split_clips_and_archive_original(
                source_video_id, [first_cut_points, second_cut_points], target_clip, user_id
              )

            {:error, reason} ->
              Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Remove a cut point between two adjacent virtual clips, merging them.

  This operation finds two adjacent clips that share the specified cut point,
  merges them into a single clip, and archives the originals to maintain
  MECE properties.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `frame_number`: Frame number of the cut point to remove
  - `user_id`: ID of the user performing the operation

  ## Returns
  - `{:ok, merged_clip}` on successful merge
  - `{:error, reason}` on validation or operation failure
  """
  @spec remove_cut_point(integer(), integer(), integer()) ::
          {:ok, Clip.t()} | {:error, any()}
  def remove_cut_point(source_video_id, frame_number, user_id) do
    Repo.transaction(fn ->
      # 1. Find two adjacent clips that share this cut point
      case find_adjacent_clips_at_frame(source_video_id, frame_number) do
        {:ok, {first_clip, second_clip}} ->
          # 2. Combine their cut points
          merged_cut_points = combine_adjacent_cut_points(
            first_clip.cut_points, second_clip.cut_points
          )

          # 3. Create new merged clip and archive originals
          create_merged_clip_and_archive_originals(
            source_video_id, merged_cut_points, [first_clip, second_clip], user_id
          )

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Move a cut point from one frame to another, adjusting adjacent clips.

  This operation finds the two clips adjacent to the old cut point,
  adjusts their boundaries to the new frame position, and updates
  their cut points to maintain MECE properties.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `old_frame`: Current frame number of the cut point
  - `new_frame`: New frame number for the cut point
  - `user_id`: ID of the user performing the operation

  ## Returns
  - `{:ok, {first_clip, second_clip}}` on successful move
  - `{:error, reason}` on validation or operation failure
  """
  @spec move_cut_point(integer(), integer(), integer(), integer()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, any()}
  def move_cut_point(source_video_id, old_frame, new_frame, user_id) do
    Repo.transaction(fn ->
      # 1. Find two adjacent clips at the old cut point
      case find_adjacent_clips_at_frame(source_video_id, old_frame) do
        {:ok, {first_clip, second_clip}} ->
          # 2. Validate new frame position
          case validate_move_frame(first_clip, second_clip, new_frame) do
            :ok ->
              # 3. Create updated cut points for both clips
              {updated_first_cut_points, updated_second_cut_points} =
                adjust_cut_points_for_move(first_clip.cut_points, second_clip.cut_points, new_frame)

              # 4. Update both clips with new boundaries
              update_adjacent_clips_for_move(
                first_clip, second_clip, updated_first_cut_points, updated_second_cut_points, user_id
              )

            {:error, reason} ->
              Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Validate MECE properties for all virtual clips of a source video.

  Ensures that all virtual clips for a source video are mutually exclusive,
  collectively exhaustive, with no gaps or overlaps.

  ## Parameters
  - `source_video_id`: ID of the source video to validate

  ## Returns
  - `:ok` if MECE properties are satisfied
  - `{:error, reason}` if validation fails
  """
  @spec validate_mece_for_source_video(integer()) :: :ok | {:error, String.t()}
  def validate_mece_for_source_video(source_video_id) do
    virtual_clips = get_virtual_clips_for_source(source_video_id)
    cut_points_list = Enum.map(virtual_clips, & &1.cut_points)

    with :ok <- ensure_no_overlaps(cut_points_list),
         :ok <- ensure_no_gaps(cut_points_list) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get all cut points for a source video in frame order.

  ## Parameters
  - `source_video_id`: ID of the source video

  ## Returns
  - List of frame numbers representing cut points
  """
  @spec get_cut_points_for_source_video(integer()) :: [integer()]
  def get_cut_points_for_source_video(source_video_id) do
    virtual_clips = get_virtual_clips_for_source(source_video_id)

    virtual_clips
    |> Enum.flat_map(fn clip ->
      [clip.cut_points["start_frame"], clip.cut_points["end_frame"]]
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Ensure complete coverage of source video by virtual clips.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `total_duration_seconds`: Total duration of the source video

  ## Returns
  - `:ok` if complete coverage exists
  - `{:error, reason}` if coverage is incomplete
  """
  @spec ensure_complete_coverage(integer(), float()) :: :ok | {:error, String.t()}
  def ensure_complete_coverage(source_video_id, total_duration_seconds) do
    virtual_clips = get_virtual_clips_for_source(source_video_id)
    cut_points_list = Enum.map(virtual_clips, & &1.cut_points)

    case ensure_complete_coverage_internal(cut_points_list, total_duration_seconds) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Private functions

  defp get_existing_virtual_clips(source_video_id) do
    from(c in Clip,
      where: c.source_video_id == ^source_video_id and c.is_virtual == true,
      order_by: [asc: c.id]
    )
    |> Repo.all()
  end

  defp validate_cut_points(cut_points) when is_list(cut_points) do
    case cut_points do
      [] ->
        {:error, "No cut points provided"}

      points ->
        case Enum.find(points, &validate_single_cut_point_error/1) do
          nil -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp validate_cut_points(_), do: {:error, "Cut points must be a list"}

  defp validate_single_cut_point(cut_point) do
    required_fields = ["start_frame", "end_frame", "start_time_seconds", "end_time_seconds"]

    case Enum.find(required_fields, fn field -> not Map.has_key?(cut_point, field) end) do
      nil ->
        case validate_cut_point_values(cut_point) do
          :ok -> :ok
          error -> error
        end

      missing_field ->
        {:error, "Missing required field: #{missing_field}"}
    end
  end

  defp validate_single_cut_point_error(cut_point) do
    case validate_single_cut_point(cut_point) do
      :ok -> nil
      error -> error
    end
  end

  defp validate_cut_point_values(cut_point) do
    start_frame = Map.get(cut_point, "start_frame")
    end_frame = Map.get(cut_point, "end_frame")
    start_time = Map.get(cut_point, "start_time_seconds")
    end_time = Map.get(cut_point, "end_time_seconds")

    cond do
      not is_integer(start_frame) or start_frame < 0 ->
        {:error, "start_frame must be a non-negative integer"}

      not is_integer(end_frame) or end_frame <= start_frame ->
        {:error, "end_frame must be an integer greater than start_frame"}

      not is_number(start_time) or start_time < 0 ->
        {:error, "start_time_seconds must be a non-negative number"}

      not is_number(end_time) or end_time <= start_time ->
        {:error, "end_time_seconds must be a number greater than start_time_seconds"}

      true ->
        :ok
    end
  end

  defp create_clips_from_validated_cut_points(source_video_id, cut_points, metadata) do
    # Check if clips already exist BEFORE starting transaction (idempotency)
    expected_identifiers =
      Enum.with_index(cut_points)
      |> Enum.map(fn {_cut_point, index} ->
        generate_virtual_clip_identifier(source_video_id, index)
      end)

    existing_clips =
      from(c in Clip,
        where: c.clip_identifier in ^expected_identifiers,
        order_by: [asc: c.id]
      )
      |> Repo.all()

    case existing_clips do
      [] ->
        # No existing clips, proceed with creation in transaction
        Repo.transaction(fn ->
          cut_points
          |> Enum.with_index()
          |> Enum.map(fn {cut_point, index} ->
            create_single_virtual_clip(source_video_id, cut_point, index, metadata)
          end)
          |> handle_clip_creation_results()
        end)

      clips when length(clips) == length(cut_points) ->
        # All expected clips exist, return them (idempotent)
        Logger.info(
          "VirtualClips: Found all #{length(clips)} existing virtual clips for source_video_id: #{source_video_id}"
        )

        {:ok, clips}

      partial_clips ->
        # Partial creation scenario - this shouldn't happen but handle gracefully
        Logger.warning(
          "VirtualClips: Found #{length(partial_clips)} of #{length(cut_points)} expected clips - cleaning up and retrying"
        )

        # Delete partial clips and retry
        clip_ids = Enum.map(partial_clips, & &1.id)
        Repo.delete_all(from(c in Clip, where: c.id in ^clip_ids))

        # Retry creation
        Repo.transaction(fn ->
          cut_points
          |> Enum.with_index()
          |> Enum.map(fn {cut_point, index} ->
            create_single_virtual_clip(source_video_id, cut_point, index, metadata)
          end)
          |> handle_clip_creation_results()
        end)
    end
  end

  defp create_single_virtual_clip(source_video_id, cut_point, index, metadata) do
    clip_identifier = generate_virtual_clip_identifier(source_video_id, index)

    clip_attrs = %{
      source_video_id: source_video_id,
      clip_identifier: clip_identifier,
      is_virtual: true,
      cut_points: cut_point,
      start_frame: Map.get(cut_point, "start_frame"),
      end_frame: Map.get(cut_point, "end_frame"),
      start_time_seconds: Map.get(cut_point, "start_time_seconds"),
      end_time_seconds: Map.get(cut_point, "end_time_seconds"),
      ingest_state: "pending_review",
      source_video_order: index + 1,
      cut_point_version: 1,
      processing_metadata: metadata
    }

    case %Clip{}
         |> Clip.changeset(clip_attrs)
         |> Repo.insert() do
      {:ok, clip} ->
        Logger.debug("VirtualClips: Created virtual clip #{clip.id} (#{clip_identifier})")
        {:ok, clip}

      {:error, changeset} ->
        # Check if this is a unique constraint error (idempotency fallback)
        case changeset.errors do
          [
            clip_identifier:
              {"has already been taken",
               [constraint: :unique, constraint_name: "clips_clip_identifier_key"]}
          ] ->
            # This clip already exists, try to find it
            case Repo.get_by(Clip, clip_identifier: Map.get(clip_attrs, :clip_identifier)) do
              %Clip{} = existing_clip ->
                Logger.debug(
                  "VirtualClips: Found existing virtual clip #{existing_clip.id} (#{existing_clip.clip_identifier})"
                )

                {:ok, existing_clip}

              nil ->
                Logger.error(
                  "VirtualClips: Unique constraint error but clip not found: #{inspect(changeset.errors)}"
                )

                {:error, changeset}
            end

          _ ->
            Logger.error(
              "VirtualClips: Failed to create virtual clip: #{inspect(changeset.errors)}"
            )

            {:error, changeset}
        end
    end
  end

  defp handle_clip_creation_results(results) do
    {successes, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    case errors do
      [] ->
        clips = Enum.map(successes, fn {:ok, clip} -> clip end)
        Logger.info("VirtualClips: Successfully created #{length(clips)} virtual clips")
        clips

      _ ->
        error_count = length(errors)
        Logger.error("VirtualClips: Failed to create #{error_count} virtual clips")
        Repo.rollback("Failed to create #{error_count} virtual clips")
    end
  end

  defp generate_virtual_clip_identifier(source_video_id, index) do
    "#{source_video_id}_virtual_clip_#{String.pad_leading(to_string(index + 1), 3, "0")}"
  end

  # Cut point operation helpers

  defp find_virtual_clip_containing_frame(source_video_id, frame_number) do
    virtual_clips = get_virtual_clips_for_source(source_video_id)

    case Enum.find(virtual_clips, fn clip ->
      start_frame = clip.cut_points["start_frame"]
      end_frame = clip.cut_points["end_frame"]
      frame_number > start_frame and frame_number < end_frame
    end) do
      nil ->
        {:error, "No virtual clip contains frame #{frame_number}"}
      clip ->
        {:ok, clip}
    end
  end

  defp validate_split_frame(clip, frame_number) do
    start_frame = clip.cut_points["start_frame"]
    end_frame = clip.cut_points["end_frame"]

    cond do
      frame_number <= start_frame ->
        {:error, "Frame #{frame_number} is at or before clip start (#{start_frame})"}
      frame_number >= end_frame ->
        {:error, "Frame #{frame_number} is at or after clip end (#{end_frame})"}
      true ->
        :ok
    end
  end

  defp split_cut_points_at_frame(cut_points, frame_number) do
    # Calculate time for the split frame (approximate based on frames)
    start_frame = cut_points["start_frame"]
    end_frame = cut_points["end_frame"]
    start_time = cut_points["start_time_seconds"]
    end_time = cut_points["end_time_seconds"]

    # Linear interpolation for time at split frame
    frame_ratio = (frame_number - start_frame) / (end_frame - start_frame)
    split_time = start_time + (end_time - start_time) * frame_ratio

    first_cut_points = %{
      "start_frame" => start_frame,
      "end_frame" => frame_number,
      "start_time_seconds" => start_time,
      "end_time_seconds" => split_time
    }

    second_cut_points = %{
      "start_frame" => frame_number,
      "end_frame" => end_frame,
      "start_time_seconds" => split_time,
      "end_time_seconds" => end_time
    }

    {first_cut_points, second_cut_points}
  end

  defp create_split_clips_and_archive_original(source_video_id, [first_cut_points, second_cut_points], original_clip, user_id) do
    # Archive original clip
    original_clip
    |> Clip.changeset(%{
      ingest_state: "archived",
      processing_metadata: Map.put(original_clip.processing_metadata || %{}, "archived_reason", "split_operation")
    })
    |> Repo.update!()

    # Create first new clip
    {:ok, first_clip} = create_virtual_clip_from_cut_points(
      source_video_id, first_cut_points, user_id, "split_first"
    )

    # Create second new clip
    {:ok, second_clip} = create_virtual_clip_from_cut_points(
      source_video_id, second_cut_points, user_id, "split_second"
    )

    # Log audit trail
    log_cut_point_operation("add", source_video_id, first_cut_points["end_frame"], nil, user_id,
      [original_clip.id, first_clip.id, second_clip.id], %{
        "original_clip_id" => original_clip.id,
        "operation" => "split_clip",
        "split_frame" => first_cut_points["end_frame"]
      })

    Logger.info("Cut point added: Split clip #{original_clip.id} into #{first_clip.id} and #{second_clip.id}")

    {:ok, {first_clip, second_clip}}
  end

  defp find_adjacent_clips_at_frame(source_video_id, frame_number) do
    virtual_clips = get_virtual_clips_for_source(source_video_id)

    # Find clip that ends at this frame
    first_clip = Enum.find(virtual_clips, fn clip ->
      clip.cut_points["end_frame"] == frame_number
    end)

    # Find clip that starts at this frame
    second_clip = Enum.find(virtual_clips, fn clip ->
      clip.cut_points["start_frame"] == frame_number
    end)

    case {first_clip, second_clip} do
      {%Clip{} = first, %Clip{} = second} ->
        {:ok, {first, second}}
      {nil, _} ->
        {:error, "No clip ends at frame #{frame_number}"}
      {_, nil} ->
        {:error, "No clip starts at frame #{frame_number}"}
    end
  end

  defp combine_adjacent_cut_points(first_cut_points, second_cut_points) do
    %{
      "start_frame" => first_cut_points["start_frame"],
      "end_frame" => second_cut_points["end_frame"],
      "start_time_seconds" => first_cut_points["start_time_seconds"],
      "end_time_seconds" => second_cut_points["end_time_seconds"]
    }
  end

  defp create_merged_clip_and_archive_originals(source_video_id, merged_cut_points, [first_clip, second_clip], user_id) do
    # Archive both original clips
    Enum.each([first_clip, second_clip], fn clip ->
      clip
      |> Clip.changeset(%{
        ingest_state: "archived",
        processing_metadata: Map.put(clip.processing_metadata || %{}, "archived_reason", "merge_operation")
      })
      |> Repo.update!()
    end)

    # Create merged clip
    {:ok, merged_clip} = create_virtual_clip_from_cut_points(
      source_video_id, merged_cut_points, user_id, "merge_result"
    )

    # Log audit trail
    log_cut_point_operation("remove", source_video_id, first_clip.cut_points["end_frame"], nil, user_id,
      [first_clip.id, second_clip.id, merged_clip.id], %{
        "original_clip_ids" => [first_clip.id, second_clip.id],
        "operation" => "merge_clips",
        "removed_frame" => first_clip.cut_points["end_frame"]
      })

    Logger.info("Cut point removed: Merged clips #{first_clip.id} and #{second_clip.id} into #{merged_clip.id}")

    {:ok, merged_clip}
  end

  defp validate_move_frame(first_clip, second_clip, new_frame) do
    first_start = first_clip.cut_points["start_frame"]
    second_end = second_clip.cut_points["end_frame"]

    cond do
      new_frame <= first_start ->
        {:error, "New frame #{new_frame} would be at or before first clip start (#{first_start})"}
      new_frame >= second_end ->
        {:error, "New frame #{new_frame} would be at or after second clip end (#{second_end})"}
      true ->
        :ok
    end
  end

  defp adjust_cut_points_for_move(first_cut_points, second_cut_points, new_frame) do
    # Calculate time for the new frame position
    first_start_frame = first_cut_points["start_frame"]
    second_end_frame = second_cut_points["end_frame"]
    first_start_time = first_cut_points["start_time_seconds"]
    second_end_time = second_cut_points["end_time_seconds"]

    # Linear interpolation for time at new frame
    total_frames = second_end_frame - first_start_frame
    total_time = second_end_time - first_start_time
    frame_offset = new_frame - first_start_frame
    new_time = first_start_time + (total_time * frame_offset / total_frames)

    updated_first_cut_points = %{
      "start_frame" => first_start_frame,
      "end_frame" => new_frame,
      "start_time_seconds" => first_start_time,
      "end_time_seconds" => new_time
    }

    updated_second_cut_points = %{
      "start_frame" => new_frame,
      "end_frame" => second_end_frame,
      "start_time_seconds" => new_time,
      "end_time_seconds" => second_end_time
    }

    {updated_first_cut_points, updated_second_cut_points}
  end

  defp update_adjacent_clips_for_move(first_clip, second_clip, updated_first_cut_points, updated_second_cut_points, user_id) do
    # Update first clip
    {:ok, updated_first} = first_clip
    |> Clip.changeset(%{
      cut_points: updated_first_cut_points,
      start_frame: updated_first_cut_points["start_frame"],
      end_frame: updated_first_cut_points["end_frame"],
      start_time_seconds: updated_first_cut_points["start_time_seconds"],
      end_time_seconds: updated_first_cut_points["end_time_seconds"],
      processing_metadata: Map.put(first_clip.processing_metadata || %{}, "last_modified_by_user_id", user_id)
    })
    |> Repo.update()

    # Update second clip
    {:ok, updated_second} = second_clip
    |> Clip.changeset(%{
      cut_points: updated_second_cut_points,
      start_frame: updated_second_cut_points["start_frame"],
      end_frame: updated_second_cut_points["end_frame"],
      start_time_seconds: updated_second_cut_points["start_time_seconds"],
      end_time_seconds: updated_second_cut_points["end_time_seconds"],
      processing_metadata: Map.put(second_clip.processing_metadata || %{}, "last_modified_by_user_id", user_id)
    })
    |> Repo.update()

    # Log audit trail
    old_frame = first_clip.cut_points["end_frame"]
    log_cut_point_operation("move", first_clip.source_video_id, updated_first_cut_points["end_frame"], old_frame, user_id,
      [first_clip.id, second_clip.id], %{
        "operation" => "move_cut_point",
        "old_frame" => old_frame,
        "new_frame" => updated_first_cut_points["end_frame"]
      })

    Logger.info("Cut point moved: Updated clips #{first_clip.id} and #{second_clip.id}")

    {:ok, {updated_first, updated_second}}
  end

  defp create_virtual_clip_from_cut_points(source_video_id, cut_points, user_id, operation_type) do
    # Generate unique identifier for this clip
    timestamp = System.system_time(:millisecond)
    clip_identifier = "#{source_video_id}_virtual_#{operation_type}_#{timestamp}"

    # Get next order number for this source video
    next_order = get_next_source_video_order(source_video_id)

    clip_attrs = %{
      source_video_id: source_video_id,
      clip_identifier: clip_identifier,
      is_virtual: true,
      cut_points: cut_points,
      start_frame: cut_points["start_frame"],
      end_frame: cut_points["end_frame"],
      start_time_seconds: cut_points["start_time_seconds"],
      end_time_seconds: cut_points["end_time_seconds"],
      ingest_state: "pending_review",
      source_video_order: next_order,
      cut_point_version: 1,
      created_by_user_id: user_id,
      processing_metadata: %{
        "created_by_user_id" => user_id,
        "operation_type" => operation_type,
        "created_at" => DateTime.utc_now()
      }
    }

    %Clip{}
    |> Clip.changeset(clip_attrs)
    |> Repo.insert()
  end

  # MECE validation helpers

  defp get_virtual_clips_for_source(source_video_id) do
    from(c in Clip,
      where: c.source_video_id == ^source_video_id and c.is_virtual == true and c.ingest_state != "archived",
      order_by: [asc: c.start_frame]
    )
    |> Repo.all()
  end

  defp ensure_no_overlaps(cut_points_list) do
    sorted_clips = Enum.sort_by(cut_points_list, &(&1["start_frame"]))

    case find_overlap_in_sorted_clips(sorted_clips) do
      nil -> :ok
      overlap -> {:error, "Overlap detected: #{inspect(overlap)}"}
    end
  end

  defp find_overlap_in_sorted_clips([]), do: nil
  defp find_overlap_in_sorted_clips([_single]), do: nil
  defp find_overlap_in_sorted_clips([first, second | rest]) do
    first_end = first["end_frame"]
    second_start = second["start_frame"]

    if first_end > second_start do
      %{
        first_clip: first,
        second_clip: second,
        overlap_frames: {second_start, first_end}
      }
    else
      find_overlap_in_sorted_clips([second | rest])
    end
  end

  defp ensure_no_gaps(cut_points_list) do
    sorted_clips = Enum.sort_by(cut_points_list, &(&1["start_frame"]))

    case find_gap_in_sorted_clips(sorted_clips) do
      nil -> :ok
      gap -> {:error, "Gap detected: #{inspect(gap)}"}
    end
  end

  defp find_gap_in_sorted_clips([]), do: nil
  defp find_gap_in_sorted_clips([_single]), do: nil
  defp find_gap_in_sorted_clips([first, second | rest]) do
    first_end = first["end_frame"]
    second_start = second["start_frame"]

    if first_end < second_start do
      %{
        first_clip: first,
        second_clip: second,
        gap_frames: {first_end, second_start}
      }
    else
      find_gap_in_sorted_clips([second | rest])
    end
  end

  defp ensure_complete_coverage_internal(cut_points_list, total_duration_seconds) do
    sorted_clips = Enum.sort_by(cut_points_list, &(&1["start_frame"]))

    case sorted_clips do
      [] ->
        {:error, "No virtual clips found"}

      clips ->
        first_clip = List.first(clips)
        last_clip = List.last(clips)

        cond do
          first_clip["start_time_seconds"] > 0.0 ->
            {:error, "Coverage gap at start: clips start at #{first_clip["start_time_seconds"]}s, not 0.0s"}

          last_clip["end_time_seconds"] < total_duration_seconds ->
            {:error, "Coverage gap at end: clips end at #{last_clip["end_time_seconds"]}s, video ends at #{total_duration_seconds}s"}

          true ->
            :ok
        end
    end
  end

  # Audit trail helpers

  defp get_next_source_video_order(source_video_id) do
    from(c in Clip,
      where: c.source_video_id == ^source_video_id and c.is_virtual == true and c.ingest_state != "archived",
      select: max(c.source_video_order)
    )
    |> Repo.one()
    |> case do
      nil -> 1
      max_order -> max_order + 1
    end
  end

  defp log_cut_point_operation(operation_type, source_video_id, frame_number, old_frame_number, user_id, affected_clip_ids, metadata) do
    attrs = %{
      source_video_id: source_video_id,
      operation_type: operation_type,
      frame_number: frame_number,
      old_frame_number: old_frame_number,
      user_id: user_id,
      affected_clip_ids: affected_clip_ids,
      metadata: metadata
    }

    %CutPointOperation{}
    |> CutPointOperation.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _operation} ->
        Logger.debug("Logged cut point operation: #{operation_type} at frame #{frame_number}")
        :ok
      {:error, changeset} ->
        Logger.error("Failed to log cut point operation: #{inspect(changeset.errors)}")
        :error
    end
  end
end
