defmodule HeatersWeb.QueryLive do
  use HeatersWeb, :live_view

  alias Heaters.Processing.Embeddings.Search, as: EmbeddingSearch
  alias Heaters.Media.Clips
  alias Heaters.Media.Clip

  # How many similar clips per page
  @per_page 12

  @impl true
  def mount(_params, _session, socket) do
    # 1) load dropdown options
    opts = EmbeddingSearch.embedded_filter_opts()

    # 2) default filters (nil means "Any")
    filters = %{model_name: nil, generation_strategy: nil, source_video_id: nil}

    # 3) pick an initial main_clip (first match or random)
    main_clip = EmbeddingSearch.random_embedded_clip(filters)

    # 4) fetch its neighbors (or empty list if none)
    similars =
      if main_clip do
        EmbeddingSearch.similar_clips(main_clip.id, filters, true, 1, @per_page)
      else
        []
      end

    socket =
      socket
      |> assign(
        filter_opts: opts,
        filters: filters,
        main_clip: main_clip,
        page: 1,
        sort_asc?: true,
        per_page: @per_page,
        similars_count: length(similars),
        form: to_form(filters, as: :filters)
      )
      |> stream(:similars, similars)

    {:ok, socket}
  end

  @impl true
  def handle_event("pick_main", %{"clip_id" => id_str}, socket) do
    id = String.to_integer(id_str)
    main = Clips.get_clip!(id)
    %{filters: f, sort_asc?: sa} = socket.assigns
    sims = EmbeddingSearch.similar_clips(id, f, sa, 1, @per_page)

    {:noreply,
     socket
     |> assign(main_clip: main, page: 1, similars_count: length(sims))
     |> stream(:similars, sims, reset: true)}
  end

  @impl true
  def handle_event("filter_changed", %{"filters" => new_f}, socket) do
    filters = %{
      model_name: maybe_nil(new_f["model_name"]),
      generation_strategy: maybe_nil(new_f["generation_strategy"]),
      source_video_id: to_int_or_nil(new_f["source_video_id"])
    }

    main_clip = EmbeddingSearch.random_embedded_clip(filters)

    similars =
      if main_clip,
        do: EmbeddingSearch.similar_clips(main_clip.id, filters, true, 1, @per_page),
        else: []

    {:noreply,
     socket
     |> assign(
       filters: filters,
       main_clip: main_clip,
       page: 1,
       sort_asc?: true,
       similars_count: length(similars),
       form: to_form(filters, as: :filters)
     )
     |> stream(:similars, similars, reset: true)}
  end

  @impl true
  def handle_event("paginate", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)
    %{main_clip: mc, filters: f, sort_asc?: sa} = socket.assigns
    similars = EmbeddingSearch.similar_clips(mc.id, f, sa, page, @per_page)
    {:noreply, 
     socket
     |> assign(page: page, similars_count: length(similars))
     |> stream(:similars, similars, reset: true)}
  end

  @impl true
  def handle_event("toggle_sort", _params, socket) do
    %{main_clip: mc, filters: f, sort_asc?: sa, page: page} = socket.assigns
    similars = EmbeddingSearch.similar_clips(mc.id, f, !sa, page, @per_page)
    {:noreply, 
     socket
     |> assign(sort_asc?: !sa, similars_count: length(similars))
     |> stream(:similars, similars, reset: true)}
  end

  @impl true
  def handle_event("randomize", _params, socket) do
    %{filters: f, sort_asc?: sa} = socket.assigns
    main_clip = EmbeddingSearch.random_embedded_clip(f)

    similars =
      if main_clip, do: EmbeddingSearch.similar_clips(main_clip.id, f, sa, 1, @per_page), else: []

    {:noreply, 
     socket
     |> assign(main_clip: main_clip, page: 1, similars_count: length(similars))
     |> stream(:similars, similars, reset: true)}
  end

  # Build a streaming-friendly URL by prefixing the CDN domain
  defp clip_url(%Clip{clip_filepath: path}) do
    cdn =
      Application.get_env(:heaters, :cloudfront_domain) ||
        raise """
        CloudFront domain not configured!
        Please set CLOUDFRONT_DOMAIN in your runtime.exs.
        """

    "https://#{cdn}/#{path}"
  end

  defp maybe_nil(""), do: nil
  defp maybe_nil(x), do: x

  defp to_int_or_nil(nil), do: nil
  defp to_int_or_nil(""), do: nil
  defp to_int_or_nil(s) when is_binary(s), do: String.to_integer(s)
end
