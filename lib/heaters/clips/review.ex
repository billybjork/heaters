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
  alias Heaters.Clips.Operations.Edits.Split.Worker, as: SplitWorker
  alias Heaters.Clips.Operations.Edits.Merge.Worker, as: MergeWorker

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
    "split" => "selected_split"
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
  def request_merge_and_fetch_next(%Clip{id: prev_id}, %Clip{id: curr_id}) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # Mark both clips as reviewed
      Repo.update_all(
        from(c in Clip, where: c.id == ^prev_id),
        set: [reviewed_at: now]
      )

      Repo.update_all(
        from(c in Clip, where: c.id == ^curr_id),
        set: [reviewed_at: now]
      )

      # Enqueue merge worker with 60-second buffer for undo
      buffer_time = DateTime.add(DateTime.utc_now(), 60, :second)

      case MergeWorker.new(%{
             clip_id_source: curr_id,
             clip_id_target: prev_id
           })
           |> Oban.insert(scheduled_at: buffer_time) do
        {:ok, _job} ->
          Logger.info("Review: Enqueued merge worker for clips #{prev_id} and #{curr_id}")

        {:error, reason} ->
          Logger.error("Review: Failed to enqueue merge worker: #{inspect(reason)}")
          Repo.rollback(reason)
      end

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
      {next_clip, %{clip_id_source: curr_id, clip_id_target: prev_id, action: "merge"}}
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
  def request_split_and_fetch_next(%Clip{id: clip_id}, frame_num) when is_integer(frame_num) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # Mark clip as reviewed
      Repo.update_all(
        from(c in Clip, where: c.id == ^clip_id),
        set: [reviewed_at: now]
      )

      # Enqueue split worker with 60-second buffer for undo
      buffer_time = DateTime.add(DateTime.utc_now(), 60, :second)

      case SplitWorker.new(%{
             clip_id: clip_id,
             split_at_frame: frame_num
           })
           |> Oban.insert(scheduled_at: buffer_time) do
        {:ok, _job} ->
          Logger.info("Review: Enqueued split worker for clip #{clip_id} at frame #{frame_num}")

        {:error, reason} ->
          Logger.error("Review: Failed to enqueue split worker: #{inspect(reason)}")
          Repo.rollback(reason)
      end

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
      {next_clip, %{clip_id: clip_id, action: "split", frame: frame_num}}
    end)
  end

  @doc """
  Cancel pending merge/split jobs for a clip to enable undo.

  This function cancels any scheduled merge or split jobs for the given clip
  within the buffer time window, allowing the user to undo the action.
  """
  def cancel_pending_jobs_for_clip(clip_id) do
    import Ecto.Query

    # Find and cancel merge jobs where this clip is involved
    merge_jobs_query =
      from(job in Oban.Job,
        where:
          job.worker == "Heaters.Clips.Operations.Edits.Merge.Worker" and
            job.state == "scheduled" and
            (fragment("?->>'clip_id_source' = ?", job.args, ^to_string(clip_id)) or
               fragment("?->>'clip_id_target' = ?", job.args, ^to_string(clip_id)))
      )

    {:ok, merge_jobs_cancelled} = Oban.cancel_all_jobs(merge_jobs_query)

    # Find and cancel split jobs for this clip
    split_jobs_query =
      from(job in Oban.Job,
        where:
          job.worker == "Heaters.Clips.Operations.Edits.Split.Worker" and
            job.state == "scheduled" and
            fragment("?->>'clip_id' = ?", job.args, ^to_string(clip_id))
      )

    {:ok, split_jobs_cancelled} = Oban.cancel_all_jobs(split_jobs_query)

    total_cancelled = merge_jobs_cancelled + split_jobs_cancelled

    if total_cancelled > 0 do
      Logger.info("Review: Cancelled #{total_cancelled} pending jobs for clip #{clip_id}")
    end

    {:ok, total_cancelled}
  end

  @doc """
  Paged list of **other** clips that belong to the same source_video.

  * sv_id       – the source_video.id that all clips must share
  * exclude_id  – the *current* clip (will be omitted from the result)
  * page        – 1-based page index
  * per         – page size (defaults to 24 thumbnails)

  Results are ordered by id ASC to make pagination deterministic even when
  background workers update timestamps.
  """
  def for_source_video_with_sprites(source_video_id, exclude_id, page, page_size) do
    Clip
    |> join(:inner, [c], ca in assoc(c, :clip_artifacts), on: ca.artifact_type == "sprite_sheet")
    |> where(
      [c, _ca],
      c.source_video_id == ^source_video_id and c.id != ^exclude_id
    )
    |> distinct([c, _ca], c.id)
    |> order_by([c, _ca], asc: c.id)
    |> offset(^((page - 1) * page_size))
    |> limit(^page_size)
    |> preload([c, ca], clip_artifacts: ca)
    |> Repo.all()
  end
end
