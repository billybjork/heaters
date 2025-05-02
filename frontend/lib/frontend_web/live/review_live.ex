defmodule FrontendWeb.ReviewLive do
  @moduledoc """
  Optimistic-UI review queue.

  * **current**  – clip on screen
  * **future**   – pre-fetched queue (max 5)
  * **history**  – last 5 clips, supports Undo (via back button)
  """

  use FrontendWeb, :live_view

  # Import the sprite-player helpers from your sprite_player.ex
  import FrontendWeb.SpritePlayer, only: [sprite_player: 1, sprite_url: 1]
  # Import your buttons component
  import FrontendWeb.ReviewButtons, only: [review_buttons: 1]

  alias Frontend.Clips
  alias Frontend.Clips.Clip

  @prefetch          6   # 1 current + 5 future
  @refill_threshold  3
  @history_limit     5

  # -------------------------------------------------------------------------
  # Mount: Initialize queue on socket assigns
  # -------------------------------------------------------------------------
  @impl true
  def mount(_params, _session, socket) do
    clips = Clips.next_pending_review_clips(@prefetch)

    case clips do
      [] ->
        {:ok, assign(socket,
                page_state: :empty,
                current:    nil,
                future:     [],
                history:    [])}

      [cur | fut] ->
        {:ok, socket
          |> assign(
            current:    cur,
            future:     fut,
            history:    [],
            page_state: :reviewing)}
    end
  end

  # -------------------------------------------------------------------------
  # Events: Handle user actions
  # -------------------------------------------------------------------------

  @impl true
  def handle_event("select", %{"action" => "merge"},
                   %{assigns: %{current: curr, history: [prev | _]}} = socket) do
    socket =
      socket
      |> push_history(curr)
      |> advance_queue()
      |> refill_future()

    {:noreply, persist_async(socket, {:merge, prev, curr})}
  end

  @impl true
  def handle_event("select", %{"action" => action}, %{assigns: %{current: clip}} = socket) do
    socket =
      socket
      |> push_history(clip)
      |> advance_queue()
      |> refill_future()

    {:noreply, persist_async(socket, clip.id, action)}
  end

  @impl true
  def handle_event("undo", _params, %{assigns: %{history: []}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("undo", _params, %{assigns: %{history: [prev | rest], current: cur, future: fut}} = socket) do
    socket =
      socket
      |> assign(
           current:    prev,
           future:     [cur | fut],
           history:    rest,
           page_state: :reviewing
         )
      |> refill_future()

    {:noreply, persist_async(socket, prev.id, "undo")}
  end

  # -------------------------------------------------------------------------
  # Background persistence
  # -------------------------------------------------------------------------

  defp persist_async(socket, {:merge, prev, curr}) do
    Phoenix.LiveView.start_async(socket, {:merge_pair, {prev.id, curr.id}}, fn ->
      Clips.request_merge_and_fetch_next(prev, curr)
    end)
  end

  defp persist_async(socket, clip_id, action) do
    Phoenix.LiveView.start_async(socket, {:persist, clip_id}, fn ->
      Clips.select_clip_and_fetch_next(%Clip{id: clip_id}, action)
    end)
  end

  # -------------------------------------------------------------------------
  # Queue refill
  # -------------------------------------------------------------------------

  defp refill_future(%{assigns: %{current: nil}} = socket), do: socket

  defp refill_future(%{assigns: assigns} = socket) do
    if length(assigns.future) < @refill_threshold do
      exclude_ids =
        [assigns.current | assigns.future ++ assigns.history]
        |> Enum.filter(& &1)
        |> Enum.map(& &1.id)

      needed    = @prefetch - (length(assigns.future) + 1)
      new_clips = Clips.next_pending_review_clips(needed, exclude_ids)

      update(socket, :future, &(&1 ++ new_clips))
    else
      socket
    end
  end

  # -------------------------------------------------------------------------
  # Helpers: push_history and advance_queue
  # -------------------------------------------------------------------------

  defp push_history(socket, clip) do
    update(socket, :history, fn history ->
      [clip | Enum.take(history, @history_limit - 1)]
    end)
  end

  defp advance_queue(%{assigns: %{future: []}} = socket) do
    assign(socket, current: nil, page_state: :empty)
  end

  defp advance_queue(%{assigns: %{future: [next | rest]}} = socket) do
    assign(socket, current: next, future: rest, page_state: :reviewing)
  end

  # -------------------------------------------------------------------------
  # Async callbacks
  # -------------------------------------------------------------------------

  @impl true
  def handle_async({:persist, _}, {:ok, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:persist, clip_id}, {:exit, reason}, socket) do
    require Logger
    Logger.error("Persist for clip #{clip_id} crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  @impl true
  def handle_async({:merge_pair, _}, {:ok, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:merge_pair, {prev_id, curr_id}}, {:exit, reason}, socket) do
    require Logger
    Logger.error("Merge #{prev_id}→#{curr_id} crashed: #{inspect(reason)}")
    {:noreply, socket}
  end
end
