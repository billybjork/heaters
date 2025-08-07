defmodule Heaters.Processing.Embed.Search do
  @moduledoc """
  Similarity search and embedding lookup functions.

  Provides vector similarity search capabilities using pgvector,
  pagination support, and filter options for finding relevant clips
  based on their embeddings.
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Media.Clip
  alias Heaters.Processing.Embed.Embedding

  @doc "All available model names, generation strategies, and source videos for embedded clips"
  def embedded_filter_opts do
    model_names =
      Embedding
      |> where([e], not is_nil(e.generation_strategy))
      |> distinct([e], e.model_name)
      |> order_by([e], asc: e.model_name)
      |> select([e], e.model_name)
      |> Repo.all()

    gen_strats =
      Embedding
      |> distinct([e], e.generation_strategy)
      |> order_by([e], asc: e.generation_strategy)
      |> select([e], e.generation_strategy)
      |> Repo.all()

    source_videos =
      from(c in Clip,
        where: c.ingest_state == :embedded,
        join: sv in assoc(c, :source_video),
        distinct: sv.id,
        order_by: sv.title,
        select: {sv.id, sv.title}
      )
      |> Repo.all()

    %{model_names: model_names, generation_strategies: gen_strats, source_videos: source_videos}
  end

  @doc "Pick one random clip in state 'embedded', respecting optional filters"
  def random_embedded_clip(%{model_name: m, generation_strategy: g, source_video_id: sv}) do
    base =
      Embedding
      |> join(
        :inner,
        [e],
        c in Clip,
        on: c.id == e.clip_id and c.ingest_state == :embedded
      )

    base =
      if m do
        from([e, c] in base, where: e.model_name == ^m)
      else
        base
      end

    base =
      if g do
        from([e, c] in base, where: e.generation_strategy == ^g)
      else
        base
      end

    base =
      if sv do
        from([e, c] in base, where: c.source_video_id == ^sv)
      else
        base
      end

    base
    |> order_by(fragment("RANDOM()"))
    |> limit(1)
    |> select([_e, c], c)
    |> Repo.one()
    |> case do
      nil -> nil
      clip -> Repo.preload(clip, :source_video)
    end
  end

  @doc """
  Given a main clip and the active filters, return page `page` of its neighbors,
  ordered by vector similarity (<=>), ascending or descending.
  """
  def similar_clips(
        main_clip_id,
        %{model_name: m, generation_strategy: g, source_video_id: sv_id},
        asc?,
        page,
        per
      ) do
    main_vec =
      Embedding
      |> where([e], e.clip_id == ^main_clip_id)
      |> maybe_filter(m, g)
      |> select([e], e.embedding)
      |> Repo.one!()

    Embedding
    |> where([e], e.clip_id != ^main_clip_id)
    |> maybe_filter(m, g)
    |> join(:inner, [e], c in Clip, on: c.id == e.clip_id and c.ingest_state == :embedded)
    # only keep clips from the chosen source video, if any
    |> (fn q -> if sv_id, do: where(q, [_, c], c.source_video_id == ^sv_id), else: q end).()
    |> order_by_similarity(main_vec, asc?)
    |> offset(^((page - 1) * per))
    |> limit(^per)
    |> select(
      [e, c],
      %{
        clip: c,
        similarity_pct: fragment("round((1 - (? <=> ?)) * 100)::int", e.embedding, ^main_vec)
      }
    )
    |> Repo.all()
    |> Enum.map(fn %{clip: clip} = row ->
      %{row | clip: Repo.preload(clip, [:clip_artifacts])}
    end)
  end

  @doc """
  Check if an embedding already exists for a clip with specific model and strategy.
  """
  @spec has_embedding?(integer(), String.t(), String.t()) :: boolean()
  def has_embedding?(clip_id, model_name, generation_strategy) do
    Embedding
    |> where([e], e.clip_id == ^clip_id)
    |> where([e], e.model_name == ^model_name)
    |> where([e], e.generation_strategy == ^generation_strategy)
    |> Repo.exists?()
  end

  # Private helper functions

  defp maybe_filter(query, nil, nil), do: query

  defp maybe_filter(query, m, g) do
    query
    |> (fn q -> if m, do: where(q, [e], e.model_name == ^m), else: q end).()
    |> (fn q -> if g, do: where(q, [e], e.generation_strategy == ^g), else: q end).()
  end

  defp order_by_similarity(query, main_embedding, true = _asc?) do
    order_by(query, [e, _c], asc: fragment("? <=> ?", e.embedding, ^main_embedding))
  end

  defp order_by_similarity(query, main_embedding, false = _desc?) do
    order_by(query, [e, _c], desc: fragment("? <=> ?", e.embedding, ^main_embedding))
  end
end
