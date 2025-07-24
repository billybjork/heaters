defmodule HeatersWeb.ReviewLive do
  use HeatersWeb, :live_view
  import Phoenix.LiveView, only: [put_flash: 3, clear_flash: 1]

  # Components / helpers
  import HeatersWeb.WebCodecsPlayer, only: [webcodecs_player: 1, proxy_video_url: 1]

  alias Heaters.Clips.Review, as: ClipReview
  alias Heaters.Clips.Clip

  # 1 current + 5 future
  @prefetch 6
  @refill_threshold 3
  @history_limit 5
  # thumbnails per page in the grid
  @sibling_page_size 24

  # -------------------------------------------------------------------------
  # Mount – build initial queue
  # -------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    clips = ClipReview.next_pending_review_clips(@prefetch)

    socket =
      socket
      |> assign(
        flash_action: nil,
        id_mode?: false,
        sibling_page: 1,
        sibling_page_size: @sibling_page_size,
        siblings: []
      )

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
        {:ok,
         socket
         |> assign(
           current: cur,
           future: fut,
           history: [],
           page_state: :reviewing
         )
         |> assign_siblings(cur, 1)}
    end
  end

  # -------------------------------------------------------------------------
  # Event handlers
  # -------------------------------------------------------------------------

  # ─────────────────────────────────────────────────────────────────────────
  # Pagination for sibling grid
  # ─────────────────────────────────────────────────────────────────────────
  @impl true
  def handle_event("change-page", %{"page" => page_str}, %{assigns: %{current: cur}} = socket) do
    {page_int, _} = Integer.parse(page_str)

    socket =
      socket
      |> assign(:sibling_page, page_int)
      |> assign_siblings(cur, page_int)

    {:noreply, socket}
  end

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
      |> assign_siblings(prev, 1)
      |> clear_flash()

    {:noreply, persist_async(socket, prev.id, "undo")}
  end

  # -------------------------------------------------------------------------
  # Async persistence helpers
  # -------------------------------------------------------------------------

  defp persist_async(socket, clip_id, action) do
    Phoenix.LiveView.start_async(socket, {:persist, clip_id}, fn ->
      ClipReview.select_clip_and_fetch_next(%Clip{id: clip_id}, action)
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
    assign(socket, current: nil, page_state: :empty, siblings: [])
  end

  defp advance_queue(%{assigns: %{future: [next | rest]}} = socket) do
    socket
    |> assign(current: next, future: rest, page_state: :reviewing)
    |> assign_siblings(next, 1)
  end

  # -------------------------------------------------------------------------
  # Sibling-grid helpers
  # -------------------------------------------------------------------------

  @doc false
  defp assign_siblings(socket, %Clip{} = clip, page) do
    # Use virtual/physical-aware sibling query
    sibs =
      for_source_video_siblings(
        clip.source_video_id,
        clip.id,
        page,
        @sibling_page_size
      )

    assign(socket, siblings: sibs, sibling_page: page)
  end

  @doc false
  defp for_source_video_siblings(source_video_id, exclude_id, page, page_size) do
    # Get clips from same source video (both virtual and physical)
    # Used for sibling navigation in the review interface
    import Ecto.Query

    exclude_clause = if is_nil(exclude_id), do: true, else: dynamic([c], c.id != ^exclude_id)

    from(c in Heaters.Clips.Clip,
      where: c.source_video_id == ^source_video_id,
      where: ^exclude_clause,
      order_by: [asc: c.id],
      offset: ^((page - 1) * page_size),
      limit: ^page_size,
      preload: [:source_video]
    )
    |> Heaters.Repo.all()
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
  # Flash verb helper
  # -------------------------------------------------------------------------
  defp flash_verb("approve"), do: "Approved"
  defp flash_verb("skip"), do: "Skipped"
  defp flash_verb("archive"), do: "Archived"
  defp flash_verb(other), do: String.capitalize(other)
end
