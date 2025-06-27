defmodule Heaters.Clips.Embeddings do
  @moduledoc """
  Embedding and similarity functions for clips.

  Handles vector similarity searches, random embedded clip selection,
  filter options for the embedding search interface, and state management
  for the embedding generation workflow.

  This module serves as the main public API and delegates to specialized
  modules for specific functionality:
  - `Heaters.Clips.Embeddings.Search` for similarity search and discovery
  - `Heaters.Clips.Embeddings.Workflow` for state management and embedding workflow
  - `Heaters.Clips.Embeddings.Types` for shared type definitions
  """

  alias Heaters.Clips.Embeddings.Search
  alias Heaters.Clips.Embeddings.Workflow
  alias Heaters.Clips.Embeddings.Types.EmbedResult

  # Re-export functions from specialized modules
  defdelegate embedded_filter_opts(), to: Search
  defdelegate random_embedded_clip(filters), to: Search
  defdelegate similar_clips(main_clip_id, filters, asc?, page, per), to: Search
  defdelegate has_embedding?(clip_id, model_name, generation_strategy), to: Search

  defdelegate start_embedding(clip_id), to: Workflow
  defdelegate complete_embedding(clip_id, embedding_data), to: Workflow
  defdelegate mark_failed(clip_or_id, failure_state, error_reason), to: Workflow
  defdelegate process_embedding_success(clip, result), to: Workflow

  # Re-export the EmbedResult type for backward compatibility
  defmodule EmbedResult do
    @moduledoc """
    Legacy alias for Heaters.Clips.Embeddings.Types.EmbedResult.
    Use Heaters.Clips.Embeddings.Types.EmbedResult directly for new code.
    """
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

    @type t :: Heaters.Clips.Embeddings.Types.EmbedResult.t()
  end
end
