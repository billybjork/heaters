defmodule Heaters.Clip.Review do
  @moduledoc """
  Review queue management and composite actions for clips.

  Handles the review workflow including queue management, event sourcing,
  and composite actions like merge, group, and split.
  """

  import Ecto.Query, warn: false
  alias Ecto.Query, as: Q
  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Events.ClipEvent


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

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        WITH ins AS (
          INSERT INTO clip_events (action, clip_id, reviewer_id)
          VALUES ($1, $2, $3)
        ), upd AS (
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
        [db_action, clip_id, reviewer_id]
      )

    next_clip =
      case rows do
        [[id]] -> load_clip_with_assocs(id)
        _ -> nil
      end

    {:ok, {next_clip, %{clip_id: clip_id, action: db_action}}}
  end



  @doc "Handle a **merge** request between *prev ⇠ current* clips."
  def request_merge_and_fetch_next(%Clip{id: prev_id}, %Clip{id: curr_id}) do
    reviewer_id = "admin"
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # log both sides
      %ClipEvent{}
      |> ClipEvent.changeset(%{
        clip_id: prev_id,
        action: "selected_merge_target",
        reviewer_id: reviewer_id
      })
      |> Repo.insert!()

      %ClipEvent{}
      |> ClipEvent.changeset(%{
        clip_id: curr_id,
        action: "selected_merge_source",
        reviewer_id: reviewer_id,
        event_data: %{"merge_target_clip_id" => prev_id}
      })
      |> Repo.insert!()

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
  end

  @doc "Handle a **group** request between *prev ⇠ current* clips."
  def request_group_and_fetch_next(%Clip{id: prev_id}, %Clip{id: curr_id}) do
    reviewer_id = "admin"
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # target side
      %ClipEvent{}
      |> ClipEvent.changeset(%{
        clip_id: prev_id,
        action: "selected_group_target",
        reviewer_id: reviewer_id
      })
      |> Repo.insert!()

      # source side
      %ClipEvent{}
      |> ClipEvent.changeset(%{
        clip_id: curr_id,
        action: "selected_group_source",
        reviewer_id: reviewer_id,
        event_data: %{"group_with_clip_id" => prev_id}
      })
      |> Repo.insert!()

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
  end

  @doc "Handle a **split** request on `clip` at `frame_num`."
  def request_split_and_fetch_next(%Clip{id: clip_id}, frame_num) when is_integer(frame_num) do
    reviewer_id = "admin"
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      # record event
      %ClipEvent{}
      |> ClipEvent.changeset(%{
        clip_id: clip_id,
        action: "selected_split",
        reviewer_id: reviewer_id,
        event_data: %{"split_at_frame" => frame_num}
      })
      |> Repo.insert!()

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



  # -------------------------------------------------------------------------
  # Sprite Generation for Review Preparation
  # -------------------------------------------------------------------------

  @doc """
  Transition a clip to "generating_sprite" state for review preparation.
  """
  @spec start_sprite_generation(integer()) :: {:ok, Clip.t()} | {:error, any()}
  def start_sprite_generation(clip_id) do
    with {:ok, clip} <- get_clip_for_update(clip_id),
         :ok <- validate_sprite_transition(clip.ingest_state) do
      update_clip(clip, %{
        ingest_state: "generating_sprite",
        last_error: nil
      })
    end
  end

  @doc """
  Mark sprite generation as complete and transition to pending_review.
  """
  @spec complete_sprite_generation(integer(), map()) :: {:ok, Clip.t()} | {:error, any()}
  def complete_sprite_generation(clip_id, sprite_data \\ %{}) do
    Repo.transaction(fn ->
      with {:ok, clip} <- get_clip_for_update(clip_id),
           {:ok, updated_clip} <- update_clip(clip, %{
             ingest_state: "pending_review",
             last_error: nil
           }),
           {:ok, _artifacts} <- maybe_create_sprite_artifacts(clip_id, sprite_data) do
        updated_clip
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Mark sprite generation as failed.
  """
  @spec mark_sprite_failed(integer(), any()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_sprite_failed(clip_id, error_reason) do
    with {:ok, clip} <- get_clip_for_update(clip_id) do
      error_message = format_error_message(error_reason)

      update_clip(clip, %{
        ingest_state: "sprite_failed",
        last_error: error_message,
        retry_count: (clip.retry_count || 0) + 1
      })
    end
  end

  @doc """
  Build S3 prefix for sprite outputs.
  """
  @spec build_sprite_prefix(Clip.t()) :: String.t()
  def build_sprite_prefix(%Clip{id: id, source_video_id: source_video_id}) do
    "source_videos/#{source_video_id}/clips/#{id}/sprites"
  end

  @doc """
  Process successful sprite generation results from Python task.
  """
  @spec process_sprite_success(Clip.t(), map()) :: {:ok, Clip.t()} | {:error, any()}
  def process_sprite_success(%Clip{} = clip, result) do
    complete_sprite_generation(clip.id, result)
  end

  # -------------------------------------------------------------------------
  # Private Helper Functions for Sprite Generation
  # -------------------------------------------------------------------------

  defp get_clip_for_update(clip_id) do
    case Repo.get(Clip, clip_id) do
      nil -> {:error, :not_found}
      clip -> {:ok, clip}
    end
  end

  defp update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update()
  end

  defp validate_sprite_transition(current_state) do
    case current_state do
      "spliced" -> :ok
      "sprite_failed" -> :ok
      _ -> {:error, :invalid_state_transition}
    end
  end

  defp maybe_create_sprite_artifacts(clip_id, sprite_data) when map_size(sprite_data) > 0 do
    artifacts_data = Map.get(sprite_data, "artifacts", [])

    if Enum.any?(artifacts_data) do
      create_sprite_artifacts(clip_id, artifacts_data)
    else
      {:ok, []}
    end
  end

  defp maybe_create_sprite_artifacts(_clip_id, _sprite_data), do: {:ok, []}

  defp create_sprite_artifacts(clip_id, artifacts_data) when is_list(artifacts_data) do
    Logger.info("Creating #{length(artifacts_data)} sprite artifacts for clip_id: #{clip_id}")

    artifacts_attrs =
      artifacts_data
      |> Enum.map(fn artifact_data ->
        build_sprite_artifact_attrs(clip_id, artifact_data)
      end)

    case Repo.insert_all(Heaters.Clip.Transform.ClipArtifact, artifacts_attrs, returning: true) do
      {count, artifacts} when count > 0 ->
        Logger.info("Successfully created #{count} sprite artifacts for clip_id: #{clip_id}")
        {:ok, artifacts}

      {0, _} ->
        Logger.error("Failed to create sprite artifacts for clip_id: #{clip_id}")
        {:error, "No artifacts were created"}
    end
  rescue
    e ->
      Logger.error("Error creating sprite artifacts for clip_id #{clip_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp build_sprite_artifact_attrs(clip_id, artifact_data) do
    now = DateTime.utc_now()

    %{
      clip_id: clip_id,
      artifact_type: Map.get(artifact_data, :artifact_type, "sprite_sheet"),
      s3_key: Map.fetch!(artifact_data, :s3_key),
      metadata: Map.get(artifact_data, :metadata, %{}),
      inserted_at: now,
      updated_at: now
    }
  end

  defp format_error_message(error_reason) when is_binary(error_reason), do: error_reason
  defp format_error_message(error_reason), do: inspect(error_reason)
end
