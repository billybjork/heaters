defmodule Heaters.Clips.VirtualClips.CutPointOperations do
  @moduledoc """
  Cut point manipulation operations for virtual clips.

  This module handles the core cut point operations that maintain MECE properties:
  - Add cut point: Split virtual clip at frame → two new virtual clips, archive original
  - Remove cut point: Merge adjacent virtual clips → new virtual clip, archive originals
  - Move cut point: Adjust boundaries of adjacent virtual clips

  All operations maintain database consistency through transactions and provide
  complete audit trails for debugging and user activity tracking.
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.VirtualClips.CutPointOperation
  require Logger

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
                source_video_id,
                [first_cut_points, second_cut_points],
                target_clip,
                user_id
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
          merged_cut_points =
            combine_adjacent_cut_points(
              first_clip.cut_points,
              second_clip.cut_points
            )

          # 3. Create new merged clip and archive originals
          create_merged_clip_and_archive_originals(
            source_video_id,
            merged_cut_points,
            [first_clip, second_clip],
            user_id
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
                adjust_cut_points_for_move(
                  first_clip.cut_points,
                  second_clip.cut_points,
                  new_frame
                )

              # 4. Update both clips with new boundaries
              update_adjacent_clips_for_move(
                first_clip,
                second_clip,
                updated_first_cut_points,
                updated_second_cut_points,
                user_id
              )

            {:error, reason} ->
              Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # Private helper functions for cut point operations

  @spec find_virtual_clip_containing_frame(integer(), integer()) ::
          {:ok, Clip.t()} | {:error, String.t()}
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

  @spec validate_split_frame(Clip.t(), integer()) :: :ok | {:error, String.t()}
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

  @spec split_cut_points_at_frame(map(), integer()) :: {map(), map()}
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

  @spec create_split_clips_and_archive_original(integer(), [map()], Clip.t(), integer()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, any()}
  defp create_split_clips_and_archive_original(
         source_video_id,
         [first_cut_points, second_cut_points],
         original_clip,
         user_id
       ) do
    # Archive original clip
    original_clip
    |> Clip.changeset(%{
      ingest_state: "archived",
      processing_metadata:
        Map.put(original_clip.processing_metadata || %{}, "archived_reason", "split_operation")
    })
    |> Repo.update!()

    # Create first new clip
    {:ok, first_clip} =
      create_virtual_clip_from_cut_points(
        source_video_id,
        first_cut_points,
        user_id,
        "split_first"
      )

    # Create second new clip
    {:ok, second_clip} =
      create_virtual_clip_from_cut_points(
        source_video_id,
        second_cut_points,
        user_id,
        "split_second"
      )

    # Log audit trail
    log_cut_point_operation(
      "add",
      source_video_id,
      first_cut_points["end_frame"],
      nil,
      user_id,
      [original_clip.id, first_clip.id, second_clip.id],
      %{
        "original_clip_id" => original_clip.id,
        "operation" => "split_clip",
        "split_frame" => first_cut_points["end_frame"]
      }
    )

    Logger.info(
      "Cut point added: Split clip #{original_clip.id} into #{first_clip.id} and #{second_clip.id}"
    )

    {:ok, {first_clip, second_clip}}
  end

  @spec find_adjacent_clips_at_frame(integer(), integer()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, String.t()}
  defp find_adjacent_clips_at_frame(source_video_id, frame_number) do
    virtual_clips = get_virtual_clips_for_source(source_video_id)

    # Find clip that ends at this frame
    first_clip =
      Enum.find(virtual_clips, fn clip ->
        clip.cut_points["end_frame"] == frame_number
      end)

    # Find clip that starts at this frame
    second_clip =
      Enum.find(virtual_clips, fn clip ->
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

  @spec combine_adjacent_cut_points(map(), map()) :: map()
  defp combine_adjacent_cut_points(first_cut_points, second_cut_points) do
    %{
      "start_frame" => first_cut_points["start_frame"],
      "end_frame" => second_cut_points["end_frame"],
      "start_time_seconds" => first_cut_points["start_time_seconds"],
      "end_time_seconds" => second_cut_points["end_time_seconds"]
    }
  end

  @spec create_merged_clip_and_archive_originals(integer(), map(), [Clip.t()], integer()) ::
          {:ok, Clip.t()} | {:error, any()}
  defp create_merged_clip_and_archive_originals(
         source_video_id,
         merged_cut_points,
         [first_clip, second_clip],
         user_id
       ) do
    # Archive both original clips
    Enum.each([first_clip, second_clip], fn clip ->
      clip
      |> Clip.changeset(%{
        ingest_state: "archived",
        processing_metadata:
          Map.put(clip.processing_metadata || %{}, "archived_reason", "merge_operation")
      })
      |> Repo.update!()
    end)

    # Create merged clip
    {:ok, merged_clip} =
      create_virtual_clip_from_cut_points(
        source_video_id,
        merged_cut_points,
        user_id,
        "merge_result"
      )

    # Log audit trail
    log_cut_point_operation(
      "remove",
      source_video_id,
      first_clip.cut_points["end_frame"],
      nil,
      user_id,
      [first_clip.id, second_clip.id, merged_clip.id],
      %{
        "original_clip_ids" => [first_clip.id, second_clip.id],
        "operation" => "merge_clips",
        "removed_frame" => first_clip.cut_points["end_frame"]
      }
    )

    Logger.info(
      "Cut point removed: Merged clips #{first_clip.id} and #{second_clip.id} into #{merged_clip.id}"
    )

    {:ok, merged_clip}
  end

  @spec validate_move_frame(Clip.t(), Clip.t(), integer()) :: :ok | {:error, String.t()}
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

  @spec adjust_cut_points_for_move(map(), map(), integer()) :: {map(), map()}
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
    new_time = first_start_time + total_time * frame_offset / total_frames

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

  @spec update_adjacent_clips_for_move(Clip.t(), Clip.t(), map(), map(), integer()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, any()}
  defp update_adjacent_clips_for_move(
         first_clip,
         second_clip,
         updated_first_cut_points,
         updated_second_cut_points,
         user_id
       ) do
    # Update first clip
    {:ok, updated_first} =
      first_clip
      |> Clip.changeset(%{
        cut_points: updated_first_cut_points,
        start_frame: updated_first_cut_points["start_frame"],
        end_frame: updated_first_cut_points["end_frame"],
        start_time_seconds: updated_first_cut_points["start_time_seconds"],
        end_time_seconds: updated_first_cut_points["end_time_seconds"],
        processing_metadata:
          Map.put(first_clip.processing_metadata || %{}, "last_modified_by_user_id", user_id)
      })
      |> Repo.update()

    # Update second clip
    {:ok, updated_second} =
      second_clip
      |> Clip.changeset(%{
        cut_points: updated_second_cut_points,
        start_frame: updated_second_cut_points["start_frame"],
        end_frame: updated_second_cut_points["end_frame"],
        start_time_seconds: updated_second_cut_points["start_time_seconds"],
        end_time_seconds: updated_second_cut_points["end_time_seconds"],
        processing_metadata:
          Map.put(second_clip.processing_metadata || %{}, "last_modified_by_user_id", user_id)
      })
      |> Repo.update()

    # Log audit trail
    old_frame = first_clip.cut_points["end_frame"]

    log_cut_point_operation(
      "move",
      first_clip.source_video_id,
      updated_first_cut_points["end_frame"],
      old_frame,
      user_id,
      [first_clip.id, second_clip.id],
      %{
        "operation" => "move_cut_point",
        "old_frame" => old_frame,
        "new_frame" => updated_first_cut_points["end_frame"]
      }
    )

    Logger.info("Cut point moved: Updated clips #{first_clip.id} and #{second_clip.id}")

    {:ok, {updated_first, updated_second}}
  end

  @spec create_virtual_clip_from_cut_points(integer(), map(), integer(), String.t()) ::
          {:ok, Clip.t()} | {:error, any()}
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

  @spec get_virtual_clips_for_source(integer()) :: [Clip.t()]
  defp get_virtual_clips_for_source(source_video_id) do
    from(c in Clip,
      where:
        c.source_video_id == ^source_video_id and c.is_virtual == true and
          c.ingest_state != "archived",
      order_by: [asc: c.start_frame]
    )
    |> Repo.all()
  end

  @spec get_next_source_video_order(integer()) :: integer()
  defp get_next_source_video_order(source_video_id) do
    from(c in Clip,
      where:
        c.source_video_id == ^source_video_id and c.is_virtual == true and
          c.ingest_state != "archived",
      select: max(c.source_video_order)
    )
    |> Repo.one()
    |> case do
      nil -> 1
      max_order -> max_order + 1
    end
  end

  @spec log_cut_point_operation(
          String.t(),
          integer(),
          integer(),
          integer() | nil,
          integer(),
          [integer()],
          map()
        ) :: :ok | :error
  defp log_cut_point_operation(
         operation_type,
         source_video_id,
         frame_number,
         old_frame_number,
         user_id,
         affected_clip_ids,
         metadata
       ) do
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
