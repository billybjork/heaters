defmodule Heaters.Clips.Embedding do
  @moduledoc """
  Embedding and similarity functions for clips.

  Handles vector similarity searches, random embedded clip selection,
  filter options for the embedding search interface, and state management
  for the embedding generation workflow.

  This module serves as the main public API and delegates to specialized
  modules for specific functionality:
  - `Heaters.Clips.Embedding.Search` for similarity search and discovery
  - `Heaters.Clips.Embedding.Workflow` for state management and embedding workflow
  - `Heaters.Clips.Embedding.Types` for shared type definitions
  """

  alias Heaters.Clips.Embedding.Search
  alias Heaters.Clips.Embedding.Workflow
  alias Heaters.Clips.Embedding.Embedding.EmbedResult

  # Re-export the EmbedResult type for backward compatibility
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
    Legacy alias for Heaters.Clips.Embedding.Embedding.EmbedResult.
    Use Heaters.Clips.Embedding.Embedding.EmbedResult directly for new code.
    """
    defstruct Heaters.Clips.Embedding.Embedding.EmbedResult.__struct__()
              |> Map.keys()
              |> Enum.reject(&(&1 == :__struct__))

    @type t :: Heaters.Clips.Embedding.Embedding.EmbedResult.t()
  end
end
