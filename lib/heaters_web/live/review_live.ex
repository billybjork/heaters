defmodule HeatersWeb.ReviewLive do
  use HeatersWeb, :live_view
  import Phoenix.LiveView, only: [put_flash: 3, clear_flash: 1, push_event: 3]

  # Components / helpers
  import HeatersWeb.StreamingVideoPlayer, only: [streaming_video_player: 1]

  alias Heaters.Review.Queue, as: ClipReview
  alias Heaters.Review.Actions, as: ClipActions
  alias Heaters.Media.Clip

  # 1 current + 5 future
  @prefetch 6
  @refill_threshold 3
  @history_limit 5

  # -------------------------------------------------------------------------
  # Mount – build initial queue
  # -------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    clips = ClipReview.next_pending_review_clips(@prefetch)

    socket =
      socket
      |> assign(flash_action: nil)

    case clips do
      [] ->
        {:ok,
         assign(socket,
           page_state: :empty,
           current: nil,
           future: [],
           history: []
         )}

      [cur | fut] ->
        # Subscribe to temp clip events for all clips
        all_clips = [cur | fut]

        Enum.each(all_clips, fn clip ->
          Phoenix.PubSub.subscribe(Heaters.PubSub, "clips:#{clip.id}")
        end)

        {:ok,
         socket
         |> assign(
           current: cur,
           future: fut,
           history: [],
           page_state: :reviewing
         )}
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
    socket =
      socket
      |> assign(flash_action: action)
      |> push_history(clip)
      |> advance_queue()
      |> refill_future()
      |> put_flash(:info, "#{flash_verb(action)} clip #{clip.id}")

    {:noreply, persist_async(socket, clip.id, action)}
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
        page_state: :reviewing
      )
      |> refill_future()
      |> clear_flash()

    {:noreply, persist_async(socket, prev.id, "undo")}
  end

  # -------------------------------------------------------------------------
  # Async persistence helpers
  # -------------------------------------------------------------------------

  defp persist_async(socket, clip_id, action) do
    Phoenix.LiveView.start_async(socket, {:persist, clip_id}, fn ->
      ClipActions.select_clip_and_fetch_next(%Clip{id: clip_id}, action)
    end)
  end

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
    assign(socket, current: nil, page_state: :empty)
  end

  defp advance_queue(%{assigns: %{future: [next | rest]}} = socket) do
    socket
    |> assign(current: next, future: rest, page_state: :reviewing)
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

    # Send event to JavaScript hook to update the video player
    result = push_event(socket, "temp_clip_ready", %{clip_id: clip_id, path: path})
    Logger.info("ReviewLive: Sent push_event temp_clip_ready")
    {:noreply, result}
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
  # Flash verb helper
  # -------------------------------------------------------------------------
  defp flash_verb("approve"), do: "Approved"
  defp flash_verb("skip"), do: "Skipped"
  defp flash_verb("archive"), do: "Archived"
  defp flash_verb(other), do: String.capitalize(other)
end
