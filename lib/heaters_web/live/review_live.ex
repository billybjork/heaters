defmodule HeatersWeb.ReviewLive do
  use HeatersWeb, :live_view
  import Phoenix.LiveView, only: [put_flash: 3, clear_flash: 1, push_event: 3, push_patch: 2]

  # Components / helpers
  import HeatersWeb.ClipPlayer, only: [clip_player: 1]

  alias Heaters.Review.Queue, as: ClipReview
  alias Heaters.Review.Actions, as: ClipActions
  alias Heaters.Media.Clip

  require Logger

  # Queue management constants
  @prefetch 6
  @refill_threshold 3
  @history_limit 5
  @sequential_prefetch_count 4

  # -------------------------------------------------------------------------
  # Mount – build initial queue
  # -------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(flash_action: nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    clip_id = params["clip"]
    prefetch_size = String.to_integer(params["prefetch"] || "#{@prefetch}")

    socket =
      case clip_id do
        nil ->
          # No specific clip requested - load default queue
          load_default_queue(socket, prefetch_size)

        clip_id_str when is_binary(clip_id_str) ->
          # Specific clip requested - center queue around it
          case Integer.parse(clip_id_str) do
            {clip_id, ""} ->
              load_queue_for_clip(socket, clip_id, prefetch_size)

            _ ->
              # Invalid clip ID - fall back to default
              load_default_queue(socket, prefetch_size)
          end
      end

    {:noreply, socket}
  end

  # -------------------------------------------------------------------------
  # Queue loading helpers
  # -------------------------------------------------------------------------

  defp load_default_queue(socket, prefetch_size) do
    clips = ClipReview.next_pending_review_clips(prefetch_size)

    case clips do
      [] ->
        assign(socket,
          page_state: :empty,
          current: nil,
          future: [],
          history: [],
          temp_clip: %{},
          pending_actions: %{},
          split_mode: false
        )

      [cur | fut] ->
        # Subscribe to temp clip events for all clips
        all_clips = [cur | fut]

        Enum.each(all_clips, fn clip ->
          Phoenix.PubSub.subscribe(Heaters.PubSub, "clips:#{clip.id}")
        end)

        # Trigger background prefetch for next clips
        trigger_background_prefetch([cur | Enum.take(fut, 2)])

        assign(socket,
          current: cur,
          future: fut,
          history: [],
          page_state: :reviewing,
          temp_clip: %{},
          pending_actions: %{},
          split_mode: false
        )
    end
  end

  defp load_queue_for_clip(socket, target_clip_id, prefetch_size) do
    # Try to load the specific clip first
    case ClipReview.get_clip_if_pending_review(target_clip_id) do
      nil ->
        # Clip not found or not in pending_review state - fall back to default
        load_default_queue(socket, prefetch_size)

      target_clip ->
        # Load clips around the target clip (before and after)
        # ~1/3 for history
        before_count = div(prefetch_size, 3)
        # rest for future
        after_count = prefetch_size - before_count - 1

        history_clips = ClipReview.clips_before(target_clip_id, before_count)
        future_clips = ClipReview.clips_after(target_clip_id, after_count)

        # Subscribe to temp clip events for all clips
        all_clips = [target_clip | history_clips ++ future_clips]

        Enum.each(all_clips, fn clip ->
          Phoenix.PubSub.subscribe(Heaters.PubSub, "clips:#{clip.id}")
        end)

        # Trigger background prefetch for current and next few clips
        trigger_background_prefetch([target_clip | Enum.take(future_clips, 2)])

        assign(socket,
          current: target_clip,
          future: future_clips,
          history: Enum.reverse(history_clips),
          page_state: :reviewing,
          temp_clip: %{},
          pending_actions: %{},
          split_mode: false
        )
    end
  end

  # -------------------------------------------------------------------------
  # Event handlers
  # -------------------------------------------------------------------------

  # ─────────────────────────────────────────────────────────────────────────
  # Generic SELECT (approve, skip, archive, …)
  #
  # Immediate Persistence Pattern:
  # Actions are persisted to database immediately via async operations.
  # This ensures archived clips are excluded from review queue right away,
  # and all state changes are durable for reliable undo functionality.
  # ─────────────────────────────────────────────────────────────────────────
  @impl true
  def handle_event("select", %{"action" => action}, %{assigns: %{current: clip}} = socket) do
    # First, persist any pending actions from previous clips
    socket = persist_all_pending_actions(socket)

    # Immediately persist the current action to database
    Phoenix.LiveView.start_async(socket, {:persist, clip.id}, fn ->
      ClipActions.select_clip_and_fetch_next(%Clip{id: clip.id}, action)
    end)

    socket =
      socket
      |> assign(flash_action: action, split_mode: false)
      |> push_history(clip)
      |> advance_queue()
      |> refill_future()
      |> put_flash(:info, "#{flash_verb(action)} clip #{clip.id}")

    # Update URL to reflect new current clip
    socket = update_url_for_current_clip(socket)

    {:noreply, socket}
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Undo - Enhanced Database-Level Reversion
  #
  # Performs both UI navigation and database-level undo:
  # 1. Calls ClipActions.select_clip_and_fetch_next(clip, "undo") to reset database state
  # 2. Navigates UI back to previous clip in history
  # 3. Reverted clips return to pending_review state and reappear in queue
  # ─────────────────────────────────────────────────────────────────────────
  @impl true
  def handle_event("undo", _params, %{assigns: %{history: []}} = socket),
    do: {:noreply, socket}

  @impl true
  def handle_event(
        "undo",
        _params,
        %{assigns: %{history: [prev | rest], current: cur, future: fut}} = socket
      ) do
    # Database-level undo: revert the last action in the database
    # This calls the database undo action which resets the clip to pending_review
    Phoenix.LiveView.start_async(socket, {:undo, cur.id}, fn ->
      ClipActions.select_clip_and_fetch_next(%Clip{id: cur.id}, "undo")
    end)

    socket =
      socket
      |> assign(
        flash_action: nil,
        current: prev,
        future: [cur | fut],
        history: rest,
        page_state: :reviewing,
        temp_clip: %{},
        split_mode: false
      )
      |> refill_future()
      |> clear_flash()
      |> put_flash(:info, "Undone - clip #{cur.id} reverted to pending review")

    # Don't update URL to preserve in-memory history state

    {:noreply, socket}
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Split Mode - Frame-by-frame navigation and cut point creation
  # ─────────────────────────────────────────────────────────────────────────
  @impl true
  def handle_event("toggle_split_mode", _params, socket) do
    new_split_mode = not socket.assigns.split_mode

    socket =
      socket
      |> assign(split_mode: new_split_mode)
      |> push_event("split_mode_changed", %{split_mode: new_split_mode})

    {:noreply, socket}
  end

  # Handle split mode changes from JavaScript hooks
  @impl true
  def handle_event("split_mode_changed", %{"active" => active}, socket) do
    {:noreply, assign(socket, split_mode: active)}
  end

  # Split operations from JavaScript FrameNavigator

  @impl true
  def handle_event(
        "split_at_time_offset",
        %{"time_offset_seconds" => time_offset_seconds},
        %{assigns: %{current: clip}} = socket
      ) do
    # Convert time offset to frame number for display purposes
    fps = clip.source_video.fps || 25.0
    frame_offset = trunc(time_offset_seconds * fps)
    frame_number = clip.start_frame + frame_offset

    # First, persist any pending actions from previous clips
    socket = persist_all_pending_actions(socket)

    # Use the time-offset approach for server-side split calculation
    Phoenix.LiveView.start_async(socket, {:split, clip.id}, fn ->
      alias Heaters.Review.Actions
      Actions.request_split_at_time_offset(clip, time_offset_seconds)
    end)

    socket =
      socket
      |> assign(flash_action: "split", split_mode: false)
      |> push_history(clip)
      |> advance_queue()
      |> refill_future()
      |> put_flash(
        :info,
        "Split clip #{clip.id} at #{time_offset_seconds}s (frame #{frame_number})"
      )

    # Update URL to reflect new current clip
    socket = update_url_for_current_clip(socket)

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "split_at_frame",
        %{"frame_number" => frame_number},
        %{assigns: %{current: clip}} = socket
      ) do
    # First, persist any pending actions from previous clips
    socket = persist_all_pending_actions(socket)

    # Execute split operation at specific frame
    Phoenix.LiveView.start_async(socket, {:split, clip.id}, fn ->
      alias Heaters.Media.Cuts.Operations

      Operations.add_cut(clip.source_video_id, frame_number, nil,
        metadata: %{operation: "split_action"}
      )
    end)

    socket =
      socket
      |> assign(flash_action: "split", split_mode: false)
      |> push_history(clip)
      |> advance_queue()
      |> refill_future()
      |> put_flash(:info, "Split clip #{clip.id} at frame #{frame_number}")

    # Update URL to reflect new current clip
    socket = update_url_for_current_clip(socket)

    {:noreply, socket}
  end

  # -------------------------------------------------------------------------
  # Async persistence helpers
  # -------------------------------------------------------------------------

  # -------------------------------------------------------------------------
  # Queue helpers
  # -------------------------------------------------------------------------

  defp refill_future(%{assigns: %{current: nil}} = socket), do: socket

  defp refill_future(%{assigns: assigns} = socket) do
    if length(assigns.future) < @refill_threshold do
      exclude_ids =
        [assigns.current | assigns.future ++ assigns.history]
        |> Enum.filter(& &1)
        |> Enum.map(& &1.id)

      needed = @prefetch - (length(assigns.future) + 1)
      new_clips = ClipReview.next_pending_review_clips(needed, exclude_ids)

      # Subscribe to temp clip events for new clips
      Enum.each(new_clips, fn clip ->
        Phoenix.PubSub.subscribe(Heaters.PubSub, "clips:#{clip.id}")
      end)

      # Trigger background prefetch for newly loaded clips
      trigger_background_prefetch(new_clips)

      update(socket, :future, &(&1 ++ new_clips))
    else
      socket
    end
  end

  defp push_history(socket, clip) do
    update(socket, :history, fn history ->
      [clip | Enum.take(history, @history_limit - 1)]
    end)
  end

  defp advance_queue(%{assigns: %{future: []}} = socket) do
    assign(socket, current: nil, page_state: :empty, temp_clip: %{})
  end

  defp advance_queue(%{assigns: %{future: [next | rest]}} = socket) do
    # Trigger background prefetch for the next few clips when advancing
    upcoming_clips = Enum.take([next | rest], 2)
    trigger_background_prefetch(upcoming_clips)

    socket
    |> assign(current: next, future: rest, page_state: :reviewing, temp_clip: %{})
  end

  # -------------------------------------------------------------------------
  # Background prefetch helpers
  # -------------------------------------------------------------------------

  defp trigger_background_prefetch(clips) when is_list(clips) do
    # Only prefetch clips without exported files in development (where sync generation causes delays)
    if Application.get_env(:heaters, :app_env) == "development" do
      clips_to_process =
        clips
        # Only clips that haven't been exported yet (nil clip_filepath)
        |> Enum.filter(fn clip -> is_nil(clip.clip_filepath) end)

      # Process immediate clips first
      Enum.each(clips_to_process, &maybe_trigger_background_generation/1)

      # Pre-warm additional clips from the same source videos for sequential review
      # Only do this if we have clips to process (avoids unnecessary DB queries)
      if length(clips_to_process) > 0 do
        trigger_sequential_prewarming(clips_to_process)
      end
    end
  end

  defp maybe_trigger_background_generation(clip) do
    # Smart Prefetch Logic:
    # Check if this clip already has a temp file or generation in progress
    # by trying to generate the URL - if it fails or is loading, queue background generation.
    # Oban uniqueness constraints prevent duplicate jobs for the same clip.
    case Heaters.Storage.S3.ClipUrls.get_video_url(clip, clip.source_video || %{}) do
      {:error, _reason} ->
        # Queue background generation via Oban worker (with uniqueness constraints)
        job_result =
          %{clip_id: clip.id}
          |> Heaters.Storage.PlaybackCache.Worker.new()
          |> Oban.insert()

        case job_result do
          {:ok, %Oban.Job{}} ->
            :ok

          {:error, %Ecto.Changeset{errors: [unique: _]}} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ReviewLive: Failed to queue job for clip #{clip.id}: #{inspect(reason)}"
            )
        end

      {:loading, nil} ->
        # Temp clip needs to be generated - queue background generation (with uniqueness constraints)
        job_result =
          %{clip_id: clip.id}
          |> Heaters.Storage.PlaybackCache.Worker.new()
          |> Oban.insert()

        case job_result do
          {:ok, %Oban.Job{}} ->
            :ok

          {:error, %Ecto.Changeset{errors: [unique: _]}} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ReviewLive: Failed to queue job for clip #{clip.id}: #{inspect(reason)}"
            )
        end

      {:ok, _url, _type} ->
        # Already available, no need to prefetch
        :ok
    end
  rescue
    # Gracefully handle any errors in prefetch - don't break the main flow
    _error -> :ok
  end

  # Pre-warm additional clips from the same source videos for sequential review
  defp trigger_sequential_prewarming(clips) when is_list(clips) do
    # Sequential Prewarming Optimization:
    # When users review clips sequentially from the same source video,
    # pre-generate the next N clips to reduce wait times. This excludes
    # clips already being processed to avoid duplicate work.

    # Get unique source video IDs from current clips
    source_video_ids =
      clips
      |> Enum.map(& &1.source_video_id)
      |> Enum.uniq()

    # Get clip IDs that are already being processed to avoid duplicates
    already_processing_ids = Enum.map(clips, & &1.id)

    # For each source video, pre-warm the next N clips in review queue order
    Enum.each(
      source_video_ids,
      &prefetch_next_clips_for_video(&1, @sequential_prefetch_count, already_processing_ids)
    )
  end

  defp prefetch_next_clips_for_video(source_video_id, prefetch_count, exclude_clip_ids) do
    # Get the next clips for this source video in review order
    # Use a direct query to avoid loading full associations for prefetch
    import Ecto.Query
    alias Heaters.Repo

    next_clips =
      from(c in Heaters.Media.Clip,
        join: sv in assoc(c, :source_video),
        where: c.source_video_id == ^source_video_id,
        where: c.ingest_state == :pending_review,
        where: is_nil(c.clip_filepath),
        # Exclude clips that are already being processed
        where: c.id not in ^exclude_clip_ids,
        # Only include clips where proxy is available (same filters as review queue)
        where: not is_nil(sv.proxy_filepath),
        where: not is_nil(sv.cache_persisted_at),
        order_by: [asc: c.id],
        limit: ^prefetch_count,
        preload: [:source_video]
      )
      |> Repo.all()

    # Queue background generation for these clips
    # Note: Oban uniqueness constraints prevent duplicate jobs for same clip_id
    Enum.each(next_clips, &maybe_trigger_background_generation/1)
  rescue
    # Gracefully handle any database errors in prefetch
    _error -> :ok
  end

  # -------------------------------------------------------------------------
  # Async callbacks
  # -------------------------------------------------------------------------

  @impl true
  def handle_async({:persist, _clip_id}, {:ok, {_next_clip, _metadata}}, socket),
    do: {:noreply, socket}

  @impl true
  def handle_async({:persist, clip_id}, {:error, reason}, socket) do
    Logger.error("Persist for clip #{clip_id} failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Action failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_async({:persist, clip_id}, {:exit, reason}, socket) do
    Logger.error("Persist for clip #{clip_id} crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Action crashed: #{inspect(reason)}")}
  end

  # Undo async handlers
  @impl true
  def handle_async({:undo, _clip_id}, {:ok, {_next_clip, _metadata}}, socket),
    do: {:noreply, socket}

  @impl true
  def handle_async({:undo, clip_id}, {:error, reason}, socket) do
    Logger.error("Undo for clip #{clip_id} failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Undo failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_async({:undo, clip_id}, {:exit, reason}, socket) do
    Logger.error("Undo for clip #{clip_id} crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Undo crashed: #{inspect(reason)}")}
  end

  # Split async handlers
  @impl true
  def handle_async({:split, _clip_id}, {:ok, {_first_clip, _second_clip}}, socket),
    do: {:noreply, socket}

  @impl true
  def handle_async({:split, clip_id}, {:error, reason}, socket) do
    Logger.error("Split for clip #{clip_id} failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Split failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_async({:split, clip_id}, {:exit, reason}, socket) do
    Logger.error("Split for clip #{clip_id} crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Split crashed: #{inspect(reason)}")}
  end

  # Background persistence handlers
  @impl true
  def handle_async({:persist_background, _clip_id}, {:ok, {_next_clip, _metadata}}, socket),
    do: {:noreply, socket}

  @impl true
  def handle_async({:persist_background, clip_id}, {:error, reason}, socket) do
    Logger.error("Background persist for clip #{clip_id} failed: #{inspect(reason)}")
    {:noreply, socket}
  end

  @impl true
  def handle_async({:persist_background, clip_id}, {:exit, reason}, socket) do
    Logger.error("Background persist for clip #{clip_id} crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  # -------------------------------------------------------------------------
  # PubSub message handlers
  # -------------------------------------------------------------------------

  @impl true
  def handle_info(
        %{
          topic: "clips:" <> _clip_id,
          event: "temp_ready",
          payload: %{path: path, clip_id: clip_id}
        },
        socket
      ) do
    require Logger
    Logger.info("ReviewLive: Received temp_ready for clip #{clip_id}, path: #{path}")

    # Check if this is for the current clip being reviewed
    current_clip_id = socket.assigns[:current] && socket.assigns.current.id

    if current_clip_id && current_clip_id == clip_id do
      # Reactive Pattern Implementation:
      # Store temp clip info in assigns separately from the clip struct.
      # This triggers the updated() lifecycle in the JavaScript ClipPlayerController,
      # which detects the state change and automatically loads the video without
      # requiring manual push_event calls or page refreshes.
      temp_clip_info = %{
        clip_id: clip_id,
        url: path,
        ready: true
      }

      {:noreply, assign(socket, temp_clip: temp_clip_info)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        %{
          topic: "clips:" <> _clip_id,
          event: "temp_error",
          payload: %{error: error, clip_id: clip_id}
        },
        socket
      ) do
    # Send error event to JavaScript hook
    {:noreply, push_event(socket, "temp_clip_error", %{clip_id: clip_id, error: error})}
  end

  # -------------------------------------------------------------------------
  # Pending actions management
  # -------------------------------------------------------------------------

  defp persist_all_pending_actions(%{assigns: %{pending_actions: pending}} = socket) do
    # Persist all pending actions to database
    Enum.each(pending, fn {clip_id, action} ->
      Phoenix.LiveView.start_async(socket, {:persist_background, clip_id}, fn ->
        ClipActions.select_clip_and_fetch_next(%Clip{id: clip_id}, action)
      end)
    end)

    # Clear all pending actions
    assign(socket, pending_actions: %{})
  end

  # -------------------------------------------------------------------------
  # URL management helpers
  # -------------------------------------------------------------------------

  defp update_url_for_current_clip(%{assigns: %{current: nil}} = socket) do
    # No current clip - navigate to base review URL
    push_patch(socket, to: ~p"/review")
  end

  defp update_url_for_current_clip(%{assigns: %{current: clip}} = socket) do
    # Update URL to reflect current clip
    push_patch(socket, to: ~p"/review?#{%{clip: clip.id}}")
  end

  # -------------------------------------------------------------------------
  # Flash verb helper
  # -------------------------------------------------------------------------
  defp flash_verb("approve"), do: "Approved"
  defp flash_verb("skip"), do: "Skipped"
  defp flash_verb("archive"), do: "Archived"
  defp flash_verb("merge"), do: "Merged"
  defp flash_verb("split"), do: "Split"
  defp flash_verb(other), do: String.capitalize(other)

  # -------------------------------------------------------------------------
  # Action availability helpers
  # -------------------------------------------------------------------------

  # Check if merge action is available for the current clip.
  #
  # Merge is only possible when:
  # 1. Current clip doesn't start at frame 0 (has a preceding clip)
  # 2. There's a cut point at the start of the current clip
  # 3. There's a preceding clip that ends where current clip starts
  defp merge_available?(%{current: nil}), do: false
  defp merge_available?(%{current: %Clip{start_frame: 0}}), do: false

  defp merge_available?(%{current: %Clip{} = clip}) do
    import Ecto.Query
    alias Heaters.Repo

    # Check if there's a preceding clip that ends where this clip starts
    preceding_clip_exists =
      from(c in Clip,
        where:
          c.source_video_id == ^clip.source_video_id and
            c.ingest_state != :archived and
            c.end_frame == ^clip.start_frame
      )
      |> Repo.one()
      |> case do
        %Clip{} -> true
        nil -> false
      end

    # Check if there's a cut at the start of this clip
    cut_exists =
      case Heaters.Media.Cuts.find_cut_at_frame(clip.source_video_id, clip.start_frame) do
        {:ok, _cut} -> true
        {:error, :not_found} -> false
      end

    preceding_clip_exists and cut_exists
  rescue
    _ -> false
  end

  # Check if group action is available for the current clip.
  #
  # Group is only possible when:
  # 1. Current clip doesn't start at frame 0 (has a preceding clip)
  # 2. There's a preceding clip that ends where current clip starts
  defp group_available?(%{current: nil}), do: false
  defp group_available?(%{current: %Clip{start_frame: 0}}), do: false

  defp group_available?(%{current: %Clip{} = clip}) do
    import Ecto.Query
    alias Heaters.Repo

    # Check if there's a preceding clip that ends where this clip starts
    from(c in Clip,
      where:
        c.source_video_id == ^clip.source_video_id and
          c.ingest_state != :archived and
          c.end_frame == ^clip.start_frame
    )
    |> Repo.one()
    |> case do
      %Clip{} -> true
      nil -> false
    end
  rescue
    _ -> false
  end

  # -------------------------------------------------------------------------
  # Process cleanup - persist any pending actions on exit
  # -------------------------------------------------------------------------

  @impl true
  def terminate(_reason, %{assigns: %{pending_actions: pending_actions}})
      when map_size(pending_actions) > 0 do
    # Persist any remaining pending actions when the LiveView shuts down
    # This prevents actions from being lost due to browser close, crash, navigation, etc.
    Task.start(fn ->
      Enum.each(pending_actions, fn {clip_id, action} ->
        try do
          ClipActions.select_clip_and_fetch_next(%Clip{id: clip_id}, action)
        rescue
          error ->
            require Logger

            Logger.warning(
              "Failed to persist pending action for clip #{clip_id} during terminate: #{inspect(error)}"
            )
        end
      end)
    end)
  end

  def terminate(_reason, _socket), do: :ok
end
