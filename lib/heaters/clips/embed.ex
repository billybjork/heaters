defmodule Heaters.Clips.Embed do
  @moduledoc """
  Embedding and similarity functions for clips.

  Handles vector similarity searches, random embedded clip selection,
  filter options for the embedding search interface, and state management
  for the embedding generation workflow.
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.Embed.Embedding
  alias Heaters.Clips.Queries, as: ClipQueries
  require Logger

  defmodule EmbedResult do
    @moduledoc """
    Structured result type for Embed transform operations.
    """

    @enforce_keys [:status, :clip_id, :embedding_id]
    defstruct [
      :status,
      :clip_id,
      :embedding_id,
      :model_name,
      :generation_strategy,
      :embedding_dim,
      :metadata,
      :duration_ms,
      :processed_at
    ]

    @type t :: %__MODULE__{
            status: String.t(),
            clip_id: integer(),
            embedding_id: integer() | nil,
            model_name: String.t() | nil,
            generation_strategy: String.t() | nil,
            embedding_dim: integer() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t() | nil
          }
  end

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
        where: c.ingest_state == "embedded",
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
        on: c.id == e.clip_id and c.ingest_state == "embedded"
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
    |> join(:inner, [e], c in Clip, on: c.id == e.clip_id and c.ingest_state == "embedded")
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

  # State management functions for embedding workflow

  @doc """
  Transition a clip to "embedding" state.
  """
  @spec start_embedding(integer()) :: {:ok, Clip.t()} | {:error, any()}
  def start_embedding(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id),
         :ok <- validate_state_transition(clip.ingest_state, "embedding") do
      update_clip(clip, %{
        ingest_state: "embedding",
        last_error: nil
      })
    end
  end

  @doc """
  Mark a clip as successfully embedded and create embedding record.
  """
  @spec complete_embedding(integer(), map()) :: {:ok, EmbedResult.t()} | {:error, any()}
  def complete_embedding(clip_id, embedding_data) do
    start_time = System.monotonic_time()

    case Repo.transaction(fn ->
           with {:ok, clip} <- ClipQueries.get_clip(clip_id),
                {:ok, updated_clip} <-
                  update_clip(clip, %{
                    ingest_state: "embedded",
                    embedded_at: DateTime.utc_now(),
                    last_error: nil
                  }),
                {:ok, embedding} <- create_embedding(clip_id, embedding_data) do
             {updated_clip, embedding}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {_updated_clip, embedding}} ->
        duration_ms =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        embed_result = %EmbedResult{
          status: "success",
          clip_id: clip_id,
          embedding_id: embedding.id,
          model_name: embedding_data["model_name"],
          generation_strategy: embedding_data["generation_strategy"],
          embedding_dim:
            if(is_list(embedding_data["embedding"]),
              do: length(embedding_data["embedding"]),
              else: nil
            ),
          metadata: Map.get(embedding_data, "metadata", %{}),
          duration_ms: duration_ms,
          processed_at: DateTime.utc_now()
        }

        {:ok, embed_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Mark a clip embedding as failed.
  """
  @spec mark_failed(Clip.t() | integer(), String.t(), any()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_failed(clip_or_id, failure_state, error_reason)

  def mark_failed(%Clip{} = clip, failure_state, error_reason) do
    error_message = format_error_message(error_reason)

    update_clip(clip, %{
      ingest_state: failure_state,
      last_error: error_message,
      retry_count: (clip.retry_count || 0) + 1
    })
  end

  def mark_failed(clip_id, failure_state, error_reason) when is_integer(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id) do
      mark_failed(clip, failure_state, error_reason)
    end
  end

  @doc """
  Process successful embedding results from Python task.
  """
  @spec process_embedding_success(Clip.t(), map()) :: {:ok, EmbedResult.t()} | {:error, any()}
  def process_embedding_success(%Clip{} = clip, result) do
    complete_embedding(clip.id, result)
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

  defp update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update()
  end

  defp validate_state_transition(current_state, target_state) do
    case {current_state, target_state} do
      # Valid transitions for embedding
      {"pending_review", "embedding"} ->
        :ok

      {"review_approved", "embedding"} ->
        :ok

      {"embedding_failed", "embedding"} ->
        :ok

      # Invalid transitions
      _ ->
        Logger.warning("Invalid state transition from '#{current_state}' to '#{target_state}'")
        {:error, :invalid_state_transition}
    end
  end

  defp create_embedding(clip_id, embedding_data) do
    attrs = %{
      clip_id: clip_id,
      model_name: Map.fetch!(embedding_data, "model_name"),
      generation_strategy: Map.fetch!(embedding_data, "generation_strategy"),
      embedding: Map.fetch!(embedding_data, "embedding"),
      metadata: Map.get(embedding_data, "metadata", %{}),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    case Repo.insert_all(Embedding, [attrs], returning: true) do
      {1, [embedding | _]} ->
        Logger.info("Successfully created embedding for clip_id: #{clip_id}")
        {:ok, embedding}

      {0, _} ->
        Logger.error("Failed to create embedding for clip_id: #{clip_id}")
        {:error, "No embedding was created"}
    end
  rescue
    e ->
      Logger.error("Error creating embedding for clip_id #{clip_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp format_error_message(error_reason) when is_binary(error_reason), do: error_reason
  defp format_error_message(error_reason), do: inspect(error_reason)
end
