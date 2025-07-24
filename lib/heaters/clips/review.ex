defmodule Heaters.Clips.Review do
  @moduledoc """
  Review queue management and composite actions for clips.

  Handles the review workflow including queue management, event sourcing,
  and composite actions like merge, group, and split.
  """

  import Ecto.Query, warn: false
  alias Ecto.Query, as: Q
  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.VirtualClips

  require Logger

  # -------------------------------------------------------------------------
  # Constants (UI → DB action map)
  # -------------------------------------------------------------------------

  @action_map %{
    "approve" => "selected_approve",
    "skip" => "selected_skip",
    "archive" => "selected_archive",
    "undo" => "selected_undo",
    "group" => "selected_group_source"
  }

  # -------------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------------

  @spec load_clip_with_assocs(integer) :: Clip.t()
  defp load_clip_with_assocs(id) do
    from(c in Clip,
      where: c.id == ^id,
      left_join: sv in assoc(c, :source_video),
      left_join: ca in assoc(c, :clip_artifacts),
      preload: [source_video: sv, clip_artifacts: ca]
    )
    |> Repo.one!()
  end

  # -------------------------------------------------------------------------
  # Public API – review queue & actions
  # -------------------------------------------------------------------------

  @doc """
  Return up to `limit` clips still awaiting review, excluding any IDs in
  `exclude_ids`.

  Clips are ordered by *id* to remain stable even if background workers update
  timestamps.
  """
  def next_pending_review_clips(limit, exclude_ids \\ []) when is_integer(limit) do
    Clip
    |> where([c], c.ingest_state == "pending_review" and is_nil(c.reviewed_at))
    |> where([c], c.id not in ^exclude_ids)
    |> order_by([c], asc: c.id)
    |> limit(^limit)
    |> preload([:source_video, :clip_artifacts])
    |> Repo.all()
  end

  @doc "Legacy single-row wrapper kept for tests / scripts."
  def next_pending_review_clip do
    next_pending_review_clips(1) |> List.first()
  end

  @doc "Execute `ui_action` for `clip`, mark it reviewed (or *un-review* on undo), and return the next clip to review in one SQL round-trip."
  def select_clip_and_fetch_next(%Clip{id: clip_id}, ui_action) do
    db_action = Map.get(@action_map, ui_action, ui_action)

    # Update clip state and fetch next in a single transaction
    Repo.transaction(fn ->
      # Handle undo action specially - cancel pending jobs and reset states
      if db_action == "selected_undo" do
        # Cancel any pending merge/split jobs for this clip
        cancel_pending_jobs_for_clip(clip_id)

        # Reset clip to pending_review state and clear grouping
        Repo.update_all(
          from(c in Clip, where: c.id == ^clip_id),
          set: [
            reviewed_at: nil,
            ingest_state: "pending_review",
            grouped_with_clip_id: nil
          ]
        )
      end

      {:ok, %{rows: rows}} =
        Repo.query(
          """
          WITH upd AS (
            UPDATE clips
            SET    reviewed_at = CASE WHEN $1 = 'selected_undo'
                                      THEN NULL
                                      ELSE NOW()
                                 END,
                   ingest_state = CASE WHEN $1 = 'selected_approve'
                                       THEN 'review_approved'
                                       WHEN $1 = 'selected_archive'
                                       THEN 'review_archived'
                                       WHEN $1 = 'selected_skip'
                                       THEN 'review_skipped'
                                       WHEN $1 = 'selected_undo'
                                       THEN 'pending_review'
                                       ELSE ingest_state
                                  END
            WHERE  id = $2
          )
          SELECT id
          FROM   clips
          WHERE  ingest_state = 'pending_review'
            AND  reviewed_at IS NULL
          ORDER  BY id
          LIMIT  1
          FOR UPDATE SKIP LOCKED;
          """,
          [db_action, clip_id]
        )

      next_clip =
        case rows do
          [[id]] -> load_clip_with_assocs(id)
          _ -> nil
        end

      {next_clip, %{clip_id: clip_id, action: db_action}}
    end)
  end

  @doc "Handle a **merge** request between *prev ⇠ current* clips."
  def request_merge_and_fetch_next(
        %Clip{is_virtual: true} = prev_clip,
        %Clip{is_virtual: true} = curr_clip
      ) do
    # VIRTUAL CLIPS: Instant merge via database cut point update
    handle_virtual_merge(prev_clip, curr_clip)
  end

  def request_merge_and_fetch_next(%Clip{} = _prev_clip, %Clip{} = _curr_clip) do
    # MIXED OR PHYSICAL CLIPS: Not supported in enhanced virtual clips architecture
    {:error, "Merge operation only supported for virtual clips"}
  end

  # Virtual clip merge: instant database operation
  defp handle_virtual_merge(%Clip{id: prev_id} = prev_clip, %Clip{id: curr_id} = curr_clip) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # Validate that both clips are from the same source video
      if prev_clip.source_video_id != curr_clip.source_video_id do
        Repo.rollback("Cannot merge clips from different source videos")
      end

      # Combine cut points to create merged virtual clip
      merged_cut_points = combine_virtual_cut_points(prev_clip.cut_points, curr_clip.cut_points)

      # Create new merged virtual clip
      case VirtualClips.create_virtual_clips_from_cut_points(
             prev_clip.source_video_id,
             [merged_cut_points],
             %{"merged_from" => [prev_id, curr_id]}
           ) do
        {:ok, [merged_clip]} ->
          # Mark original clips as merged/reviewed
          Repo.update_all(
            from(c in Clip, where: c.id in [^prev_id, ^curr_id]),
            set: [
              reviewed_at: now,
              # New state for tracking
              ingest_state: "merged_virtual",
              grouped_with_clip_id: merged_clip.id
            ]
          )

          Logger.info(
            "Review: Instant virtual merge of clips #{prev_id} and #{curr_id} → #{merged_clip.id}"
          )

          # Fetch next clip
          next_clip = fetch_next_pending_clip()

          {next_clip,
           %{
             clip_id_source: curr_id,
             clip_id_target: prev_id,
             action: "virtual_merge",
             merged_clip_id: merged_clip.id
           }}

        {:error, reason} ->
          Logger.error("Review: Failed to create merged virtual clip: #{inspect(reason)}")
          Repo.rollback(reason)
      end
    end)
  end


  @doc "Handle a **group** request between *prev ⇠ current* clips."
  def request_group_and_fetch_next(%Clip{id: prev_id}, %Clip{id: curr_id}) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # Mark both clips as reviewed, set grouping metadata, and advance to review_approved
      Repo.update_all(
        from(c in Clip, where: c.id == ^prev_id),
        set: [
          reviewed_at: now,
          grouped_with_clip_id: curr_id,
          ingest_state: "review_approved"
        ]
      )

      Repo.update_all(
        from(c in Clip, where: c.id == ^curr_id),
        set: [
          reviewed_at: now,
          grouped_with_clip_id: prev_id,
          ingest_state: "review_approved"
        ]
      )

      Logger.info(
        "Review: Grouped clips #{prev_id} and #{curr_id} - both advanced to review_approved"
      )

      # Fetch next clip
      next_id =
        Q.from(c in Clip,
          where: c.ingest_state == "pending_review" and is_nil(c.reviewed_at),
          order_by: c.id,
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED",
          select: c.id
        )
        |> Repo.one()

      next_clip = if next_id, do: load_clip_with_assocs(next_id)
      {next_clip, %{clip_id_source: curr_id, clip_id_target: prev_id, action: "group"}}
    end)
  end

  @doc "Handle a **split** request on `clip` at `frame_num`."
  def request_split_and_fetch_next(%Clip{is_virtual: true} = clip, frame_num)
      when is_integer(frame_num) do
    # VIRTUAL CLIPS: Instant split via database cut point update
    handle_virtual_split(clip, frame_num)
  end

  def request_split_and_fetch_next(%Clip{} = _clip, _frame_num) do
    # PHYSICAL CLIPS: Not supported in enhanced virtual clips architecture
    {:error, "Split operation only supported for virtual clips"}
  end

  # Virtual clip split: instant database operation
  defp handle_virtual_split(%Clip{id: clip_id} = clip, frame_num) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # Split cut points to create two new virtual clips
      case split_virtual_cut_points(clip.cut_points, frame_num) do
        {:ok, {first_cut_points, second_cut_points}} ->
          # Create two new virtual clips from split cut points
          case VirtualClips.create_virtual_clips_from_cut_points(
                 clip.source_video_id,
                 [first_cut_points, second_cut_points],
                 %{"split_from" => clip_id, "split_at_frame" => frame_num}
               ) do
            {:ok, [first_clip, second_clip]} ->
              # Mark original clip as split/reviewed
              Repo.update_all(
                from(c in Clip, where: c.id == ^clip_id),
                set: [
                  reviewed_at: now,
                  # New state for tracking
                  ingest_state: "split_virtual",
                  # Reference to first split clip
                  grouped_with_clip_id: first_clip.id
                ]
              )

              Logger.info(
                "Review: Instant virtual split of clip #{clip_id} at frame #{frame_num} → #{first_clip.id}, #{second_clip.id}"
              )

              # Fetch next clip
              next_clip = fetch_next_pending_clip()

              {next_clip,
               %{
                 clip_id: clip_id,
                 action: "virtual_split",
                 frame: frame_num,
                 new_clip_ids: [first_clip.id, second_clip.id]
               }}

            {:error, reason} ->
              Logger.error("Review: Failed to create split virtual clips: #{inspect(reason)}")
              Repo.rollback(reason)
          end

        {:error, reason} ->
          Logger.error(
            "Review: Invalid split frame #{frame_num} for virtual clip #{clip_id}: #{reason}"
          )

          Repo.rollback(reason)
      end
    end)
  end


  @doc """
  Cancel pending merge/split jobs for a clip to enable undo.

  This function cancels any scheduled merge or split jobs for the given clip
  within the buffer time window, allowing the user to undo the action.

  For virtual clips, this also handles undoing instant database operations.
  """
  def cancel_pending_jobs_for_clip(clip_id) do
    import Ecto.Query

    # Check if this is a virtual clip operation that was already completed instantly
    clip = Repo.get(Clip, clip_id)

    case clip do
      %Clip{ingest_state: state} when state in ["merged_virtual", "split_virtual"] ->
        # Virtual clip operations are instant - handle undo by reversing database changes
        handle_virtual_clip_undo(clip)

      _ ->
        # Physical clip operations - cancel pending Oban jobs
        cancel_physical_clip_jobs(clip_id)
    end
  end

  defp handle_virtual_clip_undo(
         %Clip{ingest_state: "merged_virtual", grouped_with_clip_id: merged_clip_id} = clip
       ) do
    # Undo virtual merge: delete merged clip and restore original clips
    Repo.transaction(fn ->
      # Delete the merged virtual clip
      if merged_clip_id do
        Repo.delete_all(from(c in Clip, where: c.id == ^merged_clip_id))
      end

      # Find other clips that were merged (they should have the same grouped_with_clip_id)
      merged_clips =
        from(c in Clip,
          where: c.grouped_with_clip_id == ^merged_clip_id and c.ingest_state == "merged_virtual"
        )
        |> Repo.all()

      # Restore all merged clips to pending_review
      clip_ids = [clip.id | Enum.map(merged_clips, & &1.id)]

      Repo.update_all(
        from(c in Clip, where: c.id in ^clip_ids),
        set: [
          reviewed_at: nil,
          ingest_state: "pending_review",
          grouped_with_clip_id: nil
        ]
      )

      Logger.info("Review: Undid virtual merge for clips #{inspect(clip_ids)}")
      {:ok, length(clip_ids)}
    end)
  end

  defp handle_virtual_clip_undo(
         %Clip{ingest_state: "split_virtual", grouped_with_clip_id: _first_split_id} = clip
       ) do
    # Undo virtual split: delete split clips and restore original clip
    Repo.transaction(fn ->
      # Find and delete the split clips (they should have metadata indicating they came from this clip)
      split_clips =
        from(c in Clip,
          where:
            c.is_virtual == true and
              fragment("?->>'split_from' = ?", c.processing_metadata, ^to_string(clip.id))
        )
        |> Repo.all()

      split_clip_ids = Enum.map(split_clips, & &1.id)

      if not Enum.empty?(split_clip_ids) do
        Repo.delete_all(from(c in Clip, where: c.id in ^split_clip_ids))
      end

      # Restore original clip to pending_review
      Repo.update_all(
        from(c in Clip, where: c.id == ^clip.id),
        set: [
          reviewed_at: nil,
          ingest_state: "pending_review",
          grouped_with_clip_id: nil
        ]
      )

      Logger.info(
        "Review: Undid virtual split for clip #{clip.id}, deleted split clips #{inspect(split_clip_ids)}"
      )

      {:ok, 1}
    end)
  end

  defp handle_virtual_clip_undo(_clip) do
    # Not a virtual clip operation that can be undone
    {:ok, 0}
  end

  defp cancel_physical_clip_jobs(_clip_id) do
    # Physical clip jobs no longer exist in enhanced virtual clips architecture
    {:ok, 0}
  end


  # -------------------------------------------------------------------------
  # Private helpers for virtual clip operations
  # -------------------------------------------------------------------------

  defp fetch_next_pending_clip() do
    next_id =
      Q.from(c in Clip,
        where: c.ingest_state == "pending_review" and is_nil(c.reviewed_at),
        order_by: c.id,
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED",
        select: c.id
      )
      |> Repo.one()

    if next_id, do: load_clip_with_assocs(next_id)
  end

  defp combine_virtual_cut_points(prev_cut_points, curr_cut_points) do
    # Combine two adjacent virtual clips into one merged cut point
    # prev_clip should end where curr_clip begins (or close to it)

    prev_start_frame = prev_cut_points["start_frame"]
    prev_start_time = prev_cut_points["start_time_seconds"]

    curr_end_frame = curr_cut_points["end_frame"]
    curr_end_time = curr_cut_points["end_time_seconds"]

    %{
      "start_frame" => prev_start_frame,
      "end_frame" => curr_end_frame,
      "start_time_seconds" => prev_start_time,
      "end_time_seconds" => curr_end_time
    }
  end

  defp split_virtual_cut_points(cut_points, split_frame) do
    # Split virtual clip cut points at the specified frame
    start_frame = cut_points["start_frame"]
    end_frame = cut_points["end_frame"]
    start_time = cut_points["start_time_seconds"]
    end_time = cut_points["end_time_seconds"]

    # Validate split frame is within clip bounds
    if split_frame <= start_frame or split_frame >= end_frame do
      {:error, "Split frame #{split_frame} must be between #{start_frame} and #{end_frame}"}
    else
      # Calculate time at split frame (assuming constant framerate)
      total_frames = end_frame - start_frame
      total_duration = end_time - start_time
      frames_to_split = split_frame - start_frame
      time_to_split = start_time + frames_to_split / total_frames * total_duration

      first_cut_points = %{
        "start_frame" => start_frame,
        "end_frame" => split_frame,
        "start_time_seconds" => start_time,
        "end_time_seconds" => time_to_split
      }

      second_cut_points = %{
        "start_frame" => split_frame,
        "end_frame" => end_frame,
        "start_time_seconds" => time_to_split,
        "end_time_seconds" => end_time
      }

      {:ok, {first_cut_points, second_cut_points}}
    end
  end
end
