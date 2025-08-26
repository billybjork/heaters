defmodule Heaters.Review.Actions do
  @moduledoc """
  Review action operations for clips.

  Handles the execution of review actions including approve, skip, archive,
  group, split, and undo operations. All operations are transactional and
  maintain data consistency.
  """

  import Ecto.Query, warn: false
  alias Ecto.Query, as: Q
  alias Heaters.Repo
  alias Heaters.Media.Clip
  require Logger

  # -------------------------------------------------------------------------
  # Constants (UI → DB action map)
  # -------------------------------------------------------------------------

  @action_map %{
    "approve" => "selected_approve",
    "skip" => "selected_skip",
    "archive" => "selected_archive",
    "undo" => "selected_undo",
    "group" => "selected_group_source",
    "merge" => "selected_merge"
  }

  # -------------------------------------------------------------------------
  # Public API – review actions
  # -------------------------------------------------------------------------

  @doc "Execute `ui_action` for `clip`, mark it reviewed (or *un-review* on undo), and return the next clip to review in one SQL round-trip."
  def select_clip_and_fetch_next(%Clip{id: clip_id}, ui_action) do
    db_action = Map.get(@action_map, ui_action, ui_action)

    # Update clip state and fetch next in a single transaction
    Repo.transaction(fn ->
      # Handle special actions before main SQL query
      cond do
        db_action == "selected_undo" ->
          # Cancel any pending merge/split jobs for this clip
          cancel_pending_jobs_for_clip(clip_id)

          # Reset clip to pending_review state and clear grouping
          Repo.update_all(
            from(c in Clip, where: c.id == ^clip_id),
            set: [
              reviewed_at: nil,
              ingest_state: :pending_review,
              grouped_with_clip_id: nil
            ]
          )

        db_action == "selected_merge" ->
          # Handle merge action - find and remove cut between current clip and previous clip
          handle_merge_action(clip_id)

        db_action == "selected_group_source" ->
          # Handle group action - delegate to the two-clip grouping function
          handle_group_action(clip_id)

        true ->
          # No special handling needed
          :ok
      end

      # For group actions, skip the SQL update since it's handled by handle_group_action
      {rows, _} =
        if db_action == "selected_group_source" do
          # Group actions are handled entirely by handle_group_action, just fetch next clip
          {:ok, %{rows: rows}} =
            Repo.query(
              """
              SELECT id
              FROM   clips
              WHERE  ingest_state = 'pending_review'
                AND  reviewed_at IS NULL
              ORDER  BY id
              LIMIT  1
              FOR UPDATE SKIP LOCKED;
              """,
              []
            )

          {rows, nil}
        else
          # Normal actions go through the SQL update
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
                                           WHEN $1 = 'selected_merge'
                                           THEN 'review_archived'
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

          {rows, nil}
        end

      next_clip =
        case rows do
          [[id]] -> Heaters.Review.Queue.load_clip_with_assocs(id)
          _ -> nil
        end

      {next_clip, %{clip_id: clip_id, action: db_action}}
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
          ingest_state: :review_approved
        ]
      )

      Repo.update_all(
        from(c in Clip, where: c.id == ^curr_id),
        set: [
          reviewed_at: now,
          grouped_with_clip_id: prev_id,
          ingest_state: :review_approved
        ]
      )

      Logger.info(
        "Review: Grouped clips #{prev_id} and #{curr_id} - both advanced to review_approved"
      )

      # Fetch next clip
      next_id =
        Q.from(c in Clip,
          where: c.ingest_state == :pending_review and is_nil(c.reviewed_at),
          order_by: c.id,
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED",
          select: c.id
        )
        |> Repo.one()

      next_clip = if next_id, do: Heaters.Review.Queue.load_clip_with_assocs(next_id)
      {next_clip, %{clip_id_source: curr_id, clip_id_target: prev_id, action: "group"}}
    end)
  end


  @doc """
  Handle a **split** request on `clip` at relative `time_offset_seconds`.
  
  This is the simplified server-side approach that eliminates coordinate system
  complexity by handling all frame calculations on the server using authoritative
  database FPS data.
  
  ## Parameters
  - `clip`: The clip to split
  - `time_offset_seconds`: Time offset from clip start (e.g., 1.5s into the clip)
  
  ## Returns
  - `{next_clip, metadata}` on success
  - `{:error, reason}` on failure
  
  ## Example
  - Clip spans 33.292s-35.708s in source video
  - User seeks to 1.5s relative to clip start  
  - Server calculates: 33.292s + 1.5s = 34.792s absolute time
  - Server calculates: 34.792s * 24fps = frame 835 (rounded)
  - Uses existing cuts operation at frame 835
  """
  def request_split_at_time_offset(%Clip{clip_filepath: nil} = clip, time_offset_seconds)
      when is_number(time_offset_seconds) do
    # Load source video for FPS data
    source_video = Repo.get!(Heaters.Media.Video, clip.source_video_id)
    
    # Server-side frame calculation using authoritative database FPS
    absolute_time_seconds = clip.start_time_seconds + time_offset_seconds
    
    # CRITICAL: FPS must come from database - never assume a value
    case source_video.fps do
      fps when is_number(fps) and fps > 0 ->
        absolute_frame = round(absolute_time_seconds * fps)
        
        Logger.info("""
        Review: Server-side split calculation for clip #{clip.id}:
          Clip start: #{clip.start_time_seconds}s (frame #{clip.start_frame})
          Time offset: #{time_offset_seconds}s
          Calculated absolute time: #{absolute_time_seconds}s
          FPS: #{fps}
          Calculated absolute frame: #{absolute_frame}
        """)
        
        # Validate frame is within clip boundaries
        cond do
          absolute_frame <= clip.start_frame ->
            {:error, "Split frame #{absolute_frame} is at or before clip start (#{clip.start_frame})"}
            
          absolute_frame >= clip.end_frame ->
            {:error, "Split frame #{absolute_frame} is at or after clip end (#{clip.end_frame})"}
            
          true ->
            # Use existing cuts-based split operation
            handle_virtual_split(clip, absolute_frame)
        end
        
      _ ->
        Logger.error("Review: Source video #{source_video.id} missing FPS data - cannot perform frame calculation")
        {:error, "Source video missing FPS data - frame-accurate operations require database FPS"}
    end
  end

  def request_split_at_time_offset(%Clip{}, _time_offset_seconds) do
    # EXPORTED CLIPS: Not supported in cuts-based architecture  
    {:error, "Split operation only supported for virtual clips"}
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
      %Clip{ingest_state: state} when state in [:split_virtual] ->
        # Virtual clip operations are instant - handle undo by reversing database changes
        handle_virtual_clip_undo(clip)

      _ ->
        # Physical clip operations - cancel pending Oban jobs
        cancel_physical_clip_jobs(clip_id)
    end
  end

  @doc """
  Handle a **group** request for the current clip with the immediately preceding clip.

  This action finds the preceding clip and groups them together using the existing
  `request_group_and_fetch_next/2` function. Both clips are marked as reviewed
  and advanced to review_approved state.

  ## Parameters
  - `clip_id`: ID of the current clip to group

  ## Returns
  - `:ok` if group operation succeeded
  - `{:error, reason}` if group operation failed

  ## Behavior
  - Finds the preceding clip that ends where the current clip starts
  - Uses the existing two-clip grouping logic
  - Both clips are marked as reviewed and approved
  - Sets mutual grouped_with_clip_id references
  """
  def handle_group_action(clip_id) do
    # Get the current clip to find the preceding clip
    case Repo.get(Clip, clip_id) do
      %Clip{} = current_clip ->
        # Find the preceding clip that ends where this clip starts
        preceding_clip =
          from(c in Clip,
            where:
              c.source_video_id == ^current_clip.source_video_id and
                c.ingest_state != :archived and
                c.end_frame == ^current_clip.start_frame
          )
          |> Repo.one()

        case preceding_clip do
          %Clip{} = prev_clip ->
            # Use the existing grouping logic
            case request_group_and_fetch_next(prev_clip, current_clip) do
              {:ok, {_next_clip, _metadata}} ->
                Logger.info(
                  "Review: Successfully grouped clip #{clip_id} with preceding clip #{prev_clip.id}"
                )

                :ok

              {:error, reason} ->
                Logger.warning("Review: Failed to group clip #{clip_id}: #{reason}")
                {:error, reason}
            end

          nil ->
            Logger.warning("Review: Cannot group - no preceding clip found for clip #{clip_id}")
            {:error, "No preceding clip found"}
        end

      nil ->
        Logger.warning("Review: Cannot group - clip #{clip_id} not found")
        {:error, "Clip not found"}
    end
  rescue
    error ->
      Logger.error("Review: Group operation failed for clip #{clip_id}: #{inspect(error)}")
      {:error, "Group operation failed"}
  end

  @doc """
  Handle a **merge** request for the current clip with the immediately preceding clip.

  This action removes the cut point between the current clip and the previous clip,
  effectively merging them into a single clip. The original clips are archived
  and a new merged clip is created in their place.

  ## Parameters
  - `clip_id`: ID of the current clip to merge

  ## Returns
  - `:ok` if merge operation succeeded
  - `{:error, reason}` if merge operation failed

  ## Behavior
  - Finds the cut point at the start of the current clip
  - Uses the cuts-based `remove_cut` operation to merge clips
  - Archives both original clips and creates a new merged clip
  - New merged clip will be in `pending_review` state
  """
  def handle_merge_action(clip_id) do
    # Get the current clip to find the cut point at its start
    case Repo.get(Clip, clip_id) do
      %Clip{} = clip ->
        # Find the cut at the start of this clip (which would be removed to merge with previous clip)
        case Heaters.Media.Cuts.Operations.remove_cut(
               clip.source_video_id,
               clip.start_frame,
               # user_id - nil for system operations triggered by review
               nil,
               metadata: %{
                 "triggered_by" => "review_merge",
                 "merged_clip_id" => clip_id,
                 "action_timestamp" => DateTime.utc_now()
               }
             ) do
          {:ok, merged_clip} ->
            Logger.info(
              "Review: Successfully merged clip #{clip_id} with preceding clip, created merged clip #{merged_clip.id}"
            )

            :ok

          {:error, reason} ->
            Logger.warning("Review: Failed to merge clip #{clip_id}: #{reason}")
            {:error, reason}
        end

      nil ->
        Logger.warning("Review: Cannot merge - clip #{clip_id} not found")
        {:error, "Clip not found"}
    end
  rescue
    error ->
      Logger.error("Review: Merge operation failed for clip #{clip_id}: #{inspect(error)}")
      {:error, "Merge operation failed"}
  end

  # -------------------------------------------------------------------------
  # Private helpers for virtual clip operations
  # -------------------------------------------------------------------------

  # Clip split: instant database operation using new cuts-based approach
  @spec handle_virtual_split(Clip.t(), integer()) ::
          {Clip.t() | nil, map()} | {:error, String.t()}
  defp handle_virtual_split(%Clip{id: clip_id} = clip, frame_num) do
    # Use the new cuts-based operation - this will automatically handle:
    # 1. Creating the cut at frame_num
    # 2. Archiving the original clip
    # 3. Creating two new clips based on the new cut boundaries
    case Heaters.Media.Cuts.Operations.add_cut(
           clip.source_video_id,
           frame_num,
           # user_id - nil for system operations
           nil,
           metadata: %{"triggered_by" => "review_split", "original_clip_id" => clip_id}
         ) do
      {:ok, {first_clip, second_clip}} ->
        Logger.info(
          "Review: Instant cut-based split of clip #{clip_id} at frame #{frame_num} → #{first_clip.id}, #{second_clip.id}"
        )

        # Fetch next clip
        next_clip = fetch_next_pending_clip()

        {next_clip,
         %{
           clip_id: clip_id,
           action: "cut_split",
           frame: frame_num,
           new_clip_ids: [first_clip.id, second_clip.id]
         }}

      {:error, reason} ->
        Logger.error("Review: Failed to split clip #{clip_id} at frame #{frame_num}: #{reason}")

        {:error, reason}
    end
  end

  defp handle_virtual_clip_undo(
         %Clip{ingest_state: :split_virtual, grouped_with_clip_id: _first_split_id} = clip
       ) do
    # Undo virtual split: delete split clips and restore original clip
    Repo.transaction(fn ->
      # Find and delete the split clips (they should have metadata indicating they came from this clip)
      split_clips =
        from(c in Clip,
          where:
            is_nil(c.clip_filepath) and
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
          ingest_state: :pending_review,
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

  defp fetch_next_pending_clip() do
    next_id =
      Q.from(c in Clip,
        where: c.ingest_state == :pending_review and is_nil(c.reviewed_at),
        order_by: c.id,
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED",
        select: c.id
      )
      |> Repo.one()

    if next_id, do: Heaters.Review.Queue.load_clip_with_assocs(next_id)
  end
end
