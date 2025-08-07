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
          pending_actions: %{}
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
          pending_actions: %{}
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
          pending_actions: %{}
        )
    end
  end

  # -------------------------------------------------------------------------
  # Event handlers
  # -------------------------------------------------------------------------

  # ─────────────────────────────────────────────────────────────────────────
  # Generic SELECT (approve, skip, archive, …)
  # ─────────────────────────────────────────────────────────────────────────
  @impl true
  def handle_event("select", %{"action" => action}, %{assigns: %{current: clip}} = socket) do
    # First, persist any pending actions from previous clips
    socket = persist_all_pending_actions(socket)

    socket =
      socket
      |> assign(flash_action: action)
      |> push_history(clip)
      |> track_pending_action(clip.id, action)
      |> advance_queue()
      |> refill_future()
      |> put_flash(:info, "#{flash_verb(action)} clip #{clip.id}")

    # Update URL to reflect new current clip
    socket = update_url_for_current_clip(socket)

    {:noreply, socket}
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Undo
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
    socket =
      socket
      |> assign(
        flash_action: nil,
        current: prev,
        future: [cur | fut],
        history: rest,
        page_state: :reviewing,
        temp_clip: %{}
      )
      # Clear any pending action for the clip we're returning to
      |> clear_pending_action(prev.id)
      |> refill_future()
      |> clear_flash()
      |> put_flash(:info, "Undone - showing clip #{prev.id}")

    # Undo is a pure UI operation - no database persistence
    # The previous action is effectively "cancelled" until user takes a new action
    # Don't update URL to preserve in-memory history state

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

  defp track_pending_action(socket, clip_id, action) do
    update(socket, :pending_actions, &Map.put(&1, clip_id, action))
  end

  defp clear_pending_action(socket, clip_id) do
    update(socket, :pending_actions, &Map.delete(&1, clip_id))
  end

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
  defp flash_verb(other), do: String.capitalize(other)

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
       *   │  G          │ group  │
       *   └─────────────┴────────┘
       *
       * Usage:
       *  - Hold a letter → the corresponding button highlights (is-armed)
       *  - Press ENTER while a letter is armed → commits the action
       *  - Press ⌘/Ctrl+Z to undo the last action (UI-level only)
       */
      export default {
        mounted() {
          // Map single-letter keys to their respective actions
          this.keyMap    = { a: "approve", s: "skip", d: "archive", g: "group" };
          this.armed     = null;             // currently-armed key, e.g. "a"
          this.btn       = null;             // highlighted button element

          // Key-down handler: manages arming keys and committing actions
          this._onKeyDown = (e) => {
            const tag  = (e.target.tagName || "").toLowerCase();
            const k    = e.key.toLowerCase();

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

            // 1) First press of A/S/D/G → arm and highlight
            if (this.keyMap[k] && !this.armed) {
              if (e.repeat) { e.preventDefault(); return; }
              this.armed = k;
              this.btn   = document.getElementById(`btn-${this.keyMap[k]}`);
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

        destroyed() {
          window.removeEventListener("keydown", this._onKeyDown);
          window.removeEventListener("keyup",   this._onKeyUp);
        },

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
