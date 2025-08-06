defmodule HeatersWeb.ReviewLive do
  use HeatersWeb, :live_view
  import Phoenix.LiveView, only: [put_flash: 3, clear_flash: 1, push_event: 3]

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
           history: [],
           temp_clip: %{}
         )}

      [cur | fut] ->
        # Subscribe to temp clip events for all clips
        all_clips = [cur | fut]

        Enum.each(all_clips, fn clip ->
          Phoenix.PubSub.subscribe(Heaters.PubSub, "clips:#{clip.id}")
        end)

        # Trigger background prefetch for next clips
        trigger_background_prefetch([cur | Enum.take(fut, 2)])

        {:ok,
         socket
         |> assign(
           current: cur,
           future: fut,
           history: [],
           page_state: :reviewing,
           temp_clip: %{}
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
        page_state: :reviewing,
        temp_clip: %{}
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
    # Check if this clip already has a temp file or generation in progress
    # by trying to generate the URL - if it fails or is loading, queue background generation
    case HeatersWeb.VideoUrlHelper.get_video_url(clip, clip.source_video || %{}) do
      {:error, _reason} ->
        # Queue background generation via Oban worker (with uniqueness constraints)
        job_result =
          %{clip_id: clip.id}
          |> Heaters.Storage.PlaybackCache.Worker.new()
          |> Oban.insert()

        case job_result do
          {:ok, %Oban.Job{}} ->
            Logger.debug("ReviewLive: Queued temp clip generation for clip #{clip.id}")

          {:error, %Ecto.Changeset{errors: [unique: _]}} ->
            Logger.debug("ReviewLive: Job already queued for clip #{clip.id}, skipping duplicate")

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
            Logger.debug("ReviewLive: Queued temp clip generation for clip #{clip.id}")

          {:error, %Ecto.Changeset{errors: [unique: _]}} ->
            Logger.debug("ReviewLive: Job already queued for clip #{clip.id}, skipping duplicate")

          {:error, reason} ->
            Logger.warning(
              "ReviewLive: Failed to queue job for clip #{clip.id}: #{inspect(reason)}"
            )
        end

      {:ok, _url, _type} ->
        # Already available, no need to prefetch
        Logger.debug(
          "ReviewLive: Temp clip already available for clip #{clip.id}, skipping generation"
        )

        :ok
    end
  rescue
    # Gracefully handle any errors in prefetch - don't break the main flow
    error ->
      Logger.debug("ReviewLive: Error in prefetch for clip #{clip.id}: #{inspect(error)}")
      :ok
  end

  # Pre-warm additional clips from the same source videos for sequential review
  defp trigger_sequential_prewarming(clips) when is_list(clips) do
    # Get unique source video IDs from current clips
    source_video_ids =
      clips
      |> Enum.map(& &1.source_video_id)
      |> Enum.uniq()

    # Get clip IDs that are already being processed to avoid duplicates
    already_processing_ids = Enum.map(clips, & &1.id)

    Logger.debug(
      "ReviewLive: Sequential prewarming for source videos #{inspect(source_video_ids)}, excluding already processing clips #{inspect(already_processing_ids)}"
    )

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

    Logger.debug(
      "ReviewLive: Found #{length(next_clips)} additional clips to prefetch for source video #{source_video_id}"
    )

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
      Logger.info("ReviewLive: Updating current clip #{clip_id} with temp URL: #{path}")

      # Store temp clip info in assigns separately from the clip struct
      temp_clip_info = %{
        clip_id: clip_id,
        url: path,
        ready: true
      }

      {:noreply, assign(socket, temp_clip: temp_clip_info)}
    else
      Logger.info("ReviewLive: Temp clip ready for non-current clip #{clip_id}, ignoring")
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
  # Flash verb helper
  # -------------------------------------------------------------------------
  defp flash_verb("approve"), do: "Approved"
  defp flash_verb("skip"), do: "Skipped"
  defp flash_verb("archive"), do: "Archived"
  defp flash_verb(other), do: String.capitalize(other)
end
