defmodule HeatersWeb.ReviewLive do
  use HeatersWeb, :live_view
  import Phoenix.LiveView, only: [put_flash: 3, clear_flash: 1, push_event: 3, push_patch: 2]
  alias Phoenix.LiveView.ColocatedHook

  # Components / helpers
  import HeatersWeb.ClipPlayer, only: [clip_player: 1]

  alias Heaters.Review.Queue, as: ClipReview
  alias Heaters.Review.Actions, as: ClipActions
  alias Heaters.Media.Clip

  require Logger

  # 1 current + 5 future
  @prefetch 6
  @refill_threshold 3
  @history_limit 5
  # Sequential pre-warming: generate cache for next N clips per source video
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

    flash_message =
      if new_split_mode,
        do: "Split mode active - use ←/→ arrows to navigate frames, Enter to split",
        else: "Split mode disabled"

    socket = put_flash(socket, :info, flash_message)

    {:noreply, socket}
  end

  # Direct ClipPlayer control - no LiveView events needed

  @impl true
  def handle_event(
        "split_at_frame",
        %{"frame_number" => frame_number},
        %{assigns: %{current: clip}} = socket
      ) do
    # First, persist any pending actions from previous clips
    socket = persist_all_pending_actions(socket)

    # Immediately execute the split operation
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
    case Heaters.Storage.S3.ClipUrlGenerator.get_video_url(clip, clip.source_video || %{}) do
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
  # Async callbacks (unchanged except for flash_verb)
  # -------------------------------------------------------------------------

  @impl true
  def handle_async({:persist, _}, {:ok, {_next_clip, _metadata}}, socket), do: {:noreply, socket}
  @impl true
  def handle_async({:persist, clip_id}, {:error, reason}, socket) do
    require Logger
    Logger.error("Persist for clip #{clip_id} failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Action failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_async({:persist, clip_id}, {:exit, reason}, socket) do
    require Logger
    Logger.error("Persist for clip #{clip_id} crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Action crashed: #{inspect(reason)}")}
  end

  # Undo async handlers
  @impl true
  def handle_async({:undo, _}, {:ok, {_next_clip, _metadata}}, socket), do: {:noreply, socket}
  @impl true
  def handle_async({:undo, clip_id}, {:error, reason}, socket) do
    require Logger
    Logger.error("Undo for clip #{clip_id} failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Undo failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_async({:undo, clip_id}, {:exit, reason}, socket) do
    require Logger
    Logger.error("Undo for clip #{clip_id} crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Undo crashed: #{inspect(reason)}")}
  end

  # Split async handlers
  @impl true
  def handle_async({:split, _}, {:ok, {_first_clip, _second_clip}}, socket),
    do: {:noreply, socket}

  @impl true
  def handle_async({:split, clip_id}, {:error, reason}, socket) do
    require Logger
    Logger.error("Split for clip #{clip_id} failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Split failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_async({:split, clip_id}, {:exit, reason}, socket) do
    require Logger
    Logger.error("Split for clip #{clip_id} crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Split crashed: #{inspect(reason)}")}
  end

  # Background persistence handlers (for pending actions)
  @impl true
  def handle_async({:persist_background, _}, {:ok, {_next_clip, _metadata}}, socket),
    do: {:noreply, socket}

  @impl true
  def handle_async({:persist_background, clip_id}, {:error, reason}, socket) do
    require Logger
    Logger.error("Background persist for clip #{clip_id} failed: #{inspect(reason)}")
    # Don't show error flashes for background operations
    {:noreply, socket}
  end

  @impl true
  def handle_async({:persist_background, clip_id}, {:exit, reason}, socket) do
    require Logger
    Logger.error("Background persist for clip #{clip_id} crashed: #{inspect(reason)}")
    # Don't show error flashes for background operations
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

  # -------------------------------------------------------------------------
  # Colocated Hook - Review Hotkeys
  # -------------------------------------------------------------------------

  @doc """
  Renders the colocated ReviewHotkeys JavaScript hook.

  This hook provides keyboard shortcuts for the review workflow:
  - A: Approve
  - S: Skip
  - D: Archive
  - F: Merge
  - G: Group
  - Ctrl/Cmd+Z: Undo

  The hook is embedded directly in this LiveView module to keep
  all review-related functionality together.
  """
  def review_hotkeys_script(assigns) do
    ~H"""
    <script :type={ColocatedHook} name=".ReviewHotkeys">
      /**
       * Phoenix LiveView colocated hook for keyboard review actions
       * @type {import("phoenix_live_view").Hook}
       *
       * Keyboard shortcuts for review workflow:
       *   ┌─────────────┬────────┐
       *   │ Letter-key  │ Action │
       *   ├─────────────┼────────┤
       *   │  A          │ approve│
       *   │  S          │ skip   │
       *   │  D          │ archive│
       *   │  F          │ merge  │
       *   │  G          │ group  │
       *   │  Space      │ split  │
       *   └─────────────┴────────┘
       *
       * Split mode navigation:
       *   - Space: toggle split mode
       *   - Left/Right arrows: navigate frames (when in split mode)
       *   - Enter: commit split at current frame (when in split mode)
       *   - Escape: exit split mode
       *
       * Usage:
       *  - Hold a letter → the corresponding button highlights (is-armed)
       *  - Press ENTER while a letter is armed → commits the action
       *  - Press ⌘/Ctrl+Z to undo the last action (UI-level only)
       */
      export default {
        mounted() {
          console.log("[ReviewHotkeys] Hook mounted");
          // Map single-letter keys to their respective actions
          this.keyMap    = { a: "approve", s: "skip", d: "archive", f: "merge", g: "group" };
          this.armed     = null;             // currently-armed key, e.g. "a"
          this.btn       = null;             // highlighted button element
          this.splitMode = false;            // whether split mode is active

          // Key-down handler: manages arming keys and committing actions
          this._onKeyDown = (e) => {
            const tag  = (e.target.tagName || "").toLowerCase();
            const k    = e.key.toLowerCase();

            console.log("[ReviewHotkeys] Key pressed:", k, "Split mode:", this.splitMode);

            // Let digits go into any input uninterrupted
            if (tag === "input") {
              return;
            }

            // Undo – ⌘/Ctrl+Z (UI-level only)
            if ((e.metaKey || e.ctrlKey) && k === "z") {
              this.pushEvent("undo", {});
              this._reset();
              e.preventDefault();
              return;
            }

            // Split mode handling
            if (this._isInSplitMode()) {
              this._handleSplitModeKeys(e, k);
              return;
            }


            // Arrow keys - enter split mode if not already in it, or navigate if in split mode
            if (k === "arrowleft" || k === "arrowright") {
              const mainElement = document.querySelector("#review");
              const isCurrentlyInSplitMode = mainElement?.classList.contains("split-mode-active");

              if (!isCurrentlyInSplitMode) {
                // Enter split mode and control ClipPlayer directly
                console.log("[ReviewHotkeys] Arrow key pressed - entering split mode");
                this.pushEvent("toggle_split_mode", {});
                this._enterSplitMode();
                e.preventDefault();
                return;
              }

              // Already in split mode - navigate frames directly
              this._navigateFrames(k === "arrowleft" ? "backward" : "forward");
              e.preventDefault();
              return;
            }

            // 1) First press of A/S/D/G/F → arm and highlight (if button is not disabled)
            if (this.keyMap[k] && !this.armed) {
              if (e.repeat) { e.preventDefault(); return; }
              const targetBtn = document.getElementById(`btn-${this.keyMap[k]}`);

              // Don't arm if button is disabled
              if (targetBtn?.disabled) {
                e.preventDefault();
                return;
              }

              this.armed = k;
              this.btn   = targetBtn;
              this.btn?.classList.add("is-armed");
              e.preventDefault();
              return;
            }

            // 2) ENTER commits the armed action
            if (e.key === "Enter") {
              // If a letter is armed, commit that action
              if (this.armed) {
                const action  = this.keyMap[this.armed];
                const payload = { action };
                this.pushEvent("select", payload);
                this._reset();
                e.preventDefault();
              }
            }
          };

          // Key-up handler: clears the button highlight
          this._onKeyUp = (e) => {
            if (e.key.toLowerCase() === this.armed) {
              this._reset();
            }
          };

          window.addEventListener("keydown", this._onKeyDown);
          window.addEventListener("keyup",   this._onKeyUp);
        },

        updated() {
          // Check if split mode state changed in the DOM
          const mainElement = document.querySelector("#review");
          if (mainElement) {
            const isNowSplitMode = mainElement.classList.contains("split-mode-active");
            if (isNowSplitMode !== this.splitMode) {
              this.splitMode = isNowSplitMode;
              console.log("[ReviewHotkeys] Split mode updated from DOM:", this.splitMode);
            }
          }
        },

        destroyed() {
          window.removeEventListener("keydown", this._onKeyDown);
          window.removeEventListener("keyup",   this._onKeyUp);
        },

        // Handle LiveView events
        handleEvent(event, payload) {
          console.log("[ReviewHotkeys] Received event:", event, payload);
          
          if (event === "split_mode_changed") {
            if (!payload.split_mode) {
              // Exiting split mode - restore ClipPlayer
              console.log("[ReviewHotkeys] Exiting split mode - restoring ClipPlayer");
              this._exitSplitMode();
            }
            
            this.splitMode = payload.split_mode;
            console.log("[ReviewHotkeys] Split mode updated from LiveView:", this.splitMode);
          }
        },

        // Check current split mode from DOM (more reliable than internal state)
        _isInSplitMode() {
          const mainElement = document.querySelector("#review");
          return mainElement?.classList.contains("split-mode-active") || false;
        },

        // Simple direct ClipPlayer control methods
        _enterSplitMode() {
          console.log("[ReviewHotkeys] Entering split mode - finding ClipPlayer");
          const video = document.querySelector(".video-player");
          if (video && video._clipPlayer) {
            video._clipPlayer.enterSplitMode();
            console.log("[ReviewHotkeys] ClipPlayer enterSplitMode called");
          } else {
            console.log("[ReviewHotkeys] ClipPlayer not found or not ready");
          }
        },

        _exitSplitMode() {
          console.log("[ReviewHotkeys] Exiting split mode - restoring ClipPlayer");
          const video = document.querySelector(".video-player");
          if (video && video._clipPlayer) {
            video._clipPlayer.exitSplitMode();
            console.log("[ReviewHotkeys] ClipPlayer exitSplitMode called");
          }
        },

        _navigateFrames(direction) {
          console.log("[ReviewHotkeys] Navigating frames:", direction);
          const video = document.querySelector(".video-player");
          if (video && video._clipPlayer) {
            video._clipPlayer.navigateFrames(direction);
            console.log("[ReviewHotkeys] ClipPlayer navigateFrames called");
          }
        },

        // Handle split mode keyboard navigation
        _handleSplitModeKeys(e, k) {
          console.log("[ReviewHotkeys] Split mode key handler:", k);

          // Arrow keys for frame navigation directly
          if (k === "arrowleft" || k === "arrowright") {
            const direction = k === "arrowleft" ? "backward" : "forward";
            this._navigateFrames(direction);
            e.preventDefault();
            return;
          }

          // Escape exits split mode
          if (e.key === "Escape") {
            console.log("[ReviewHotkeys] Escape key - exiting split mode");
            this.pushEvent("toggle_split_mode", {});
            this._exitSplitMode();
            e.preventDefault();
            return;
          }

          // Enter commits split at current frame
          if (e.key === "Enter") {
            console.log("[ReviewHotkeys] Enter key - attempting split");

            // Get current video time for frame calculation
            const video = document.querySelector(".video-player");
            if (video) {
              const currentTime = video.currentTime;
              const fps = this._estimateFPS();

              // Get clip start frame from the video element's data attributes
              const clipInfo = this._getClipInfo();
              const clipStartFrame = clipInfo ? clipInfo.start_frame || 0 : 0;
              const relativeFrameNumber = Math.round(currentTime * fps);
              const absoluteFrameNumber = clipStartFrame + relativeFrameNumber;

              console.log("[ReviewHotkeys] Split calculation - currentTime:", currentTime, "fps:", fps, "startFrame:", clipStartFrame, "relativeFrame:", relativeFrameNumber, "absoluteFrame:", absoluteFrameNumber);

              this.pushEvent("split_at_frame", { frame_number: absoluteFrameNumber });
            } else {
              console.log("[ReviewHotkeys] No video element found for split");
            }
            e.preventDefault();
            return;
          }
        },


        // Estimate FPS for frame calculations (fallback to 30fps)
        _estimateFPS() {
          // Could get from clip metadata in the future
          return 30;
        },

        // Get clip information from video player
        _getClipInfo() {
          const videoElement = document.querySelector('video[phx-hook=".ClipPlayer"]');
          if (videoElement && videoElement.dataset.clipInfo) {
            try {
              return JSON.parse(videoElement.dataset.clipInfo);
            } catch (error) {
              console.error("Failed to parse clip info:", error);
            }
          }
          return null;
        },

        // Handle LiveView events (no longer needed since we use DOM-based state)
        // handleEvent(event, payload) {
        //   console.log("[ReviewHotkeys] Received event:", event, payload);
        //   if (event === "split_mode_changed") {
        //     this.splitMode = payload.split_mode;
        //     console.log("[ReviewHotkeys] Split mode changed to:", this.splitMode);
        //
        //     // Pause video when entering split mode
        //     if (this.splitMode && this.videoPlayer && this.videoPlayer.video) {
        //       this.videoPlayer.video.pause();
        //       console.log("[ReviewHotkeys] Video paused for split mode");
        //     }
        //
        //     // Update UI to indicate split mode
        //     document.body.classList.toggle("split-mode-active", this.splitMode);
        //     console.log("[ReviewHotkeys] Body class split-mode-active:", document.body.classList.contains("split-mode-active"));
        //   }
        // },

        // Reset armed state and button highlight
        _reset() {
          this.btn?.classList.remove("is-armed");
          this.armed = this.btn = null;
        }
      }
    </script>
    """
  end
end
