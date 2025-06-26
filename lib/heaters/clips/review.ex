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
  alias Heaters.Events

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

  @doc "Log `ui_action` for `clip`, mark it reviewed (or *un-review* on undo), and return the next clip to review in one SQL round-trip."
  def select_clip_and_fetch_next(%Clip{id: clip_id}, ui_action) do
    # TODO: pull from auth
    reviewer_id = "admin"
    db_action = Map.get(@action_map, ui_action, ui_action)

    # Log the event using Events context
    case Events.log_review_action(clip_id, db_action, reviewer_id) do
      {:ok, _event} ->
        # Update clip state and fetch next
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

        {:ok, {next_clip, %{clip_id: clip_id, action: db_action}}}

      {:error, reason} ->
        Logger.error(
          "Review: Failed to log review action for clip #{clip_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc "Handle a **merge** request between *prev ⇠ current* clips."
  def request_merge_and_fetch_next(%Clip{id: prev_id}, %Clip{id: curr_id}) do
    reviewer_id = "admin"
    now = DateTime.utc_now()

    # Log merge events using Events context
    case Events.log_merge_action(prev_id, curr_id, reviewer_id) do
      {:ok, _events} ->
        Repo.transaction(fn ->
          # mark reviewed & attach metadata
          Repo.update_all(
            from(c in Clip, where: c.id == ^prev_id),
            set: [reviewed_at: now, processing_metadata: %{"merge_source_clip_id" => curr_id}]
          )

          Repo.update_all(
            from(c in Clip, where: c.id == ^curr_id),
            set: [reviewed_at: now, processing_metadata: %{"merge_target_clip_id" => prev_id}]
          )

          # fetch next job
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

      {:error, reason} ->
        Logger.error(
          "Review: Failed to log merge action for clips #{prev_id} and #{curr_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc "Handle a **group** request between *prev ⇠ current* clips."
  def request_group_and_fetch_next(%Clip{id: prev_id}, %Clip{id: curr_id}) do
    reviewer_id = "admin"
    now = DateTime.utc_now()

    # Log group events using Events context
    case Events.log_group_action(prev_id, curr_id, reviewer_id) do
      {:ok, _events} ->
        Repo.transaction(fn ->
          # mark reviewed
          Repo.update_all(
            from(c in Clip, where: c.id == ^curr_id),
            set: [reviewed_at: now]
          )

          # fetch next job
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

      {:error, reason} ->
        Logger.error(
          "Review: Failed to log group action for clips #{prev_id} and #{curr_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc "Handle a **split** request on `clip` at `frame_num`."
  def request_split_and_fetch_next(%Clip{id: clip_id}, frame_num) when is_integer(frame_num) do
    reviewer_id = "admin"
    now = DateTime.utc_now()

    # Log split event using Events context
    case Events.log_split_action(clip_id, frame_num, reviewer_id) do
      {:ok, _event} ->
        Repo.transaction(fn ->
          # mark reviewed & attach metadata
          Repo.update_all(
            from(c in Clip, where: c.id == ^clip_id),
            set: [reviewed_at: now, processing_metadata: %{"split_at_frame" => frame_num}]
          )

          # fetch next clip
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

      {:error, reason} ->
        Logger.error("Review: Failed to log split action for clip #{clip_id}: #{inspect(reason)}")
        {:error, reason}
    end
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
