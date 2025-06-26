defmodule Heaters.Clips.Embedding.Types do
  @moduledoc """
  Shared type definitions for embedding operations.

  This module contains the EmbedResult struct and other types used
  across embedding operations, following the functional domain modeling
  pattern established in the Operations modules.
  """

  defmodule EmbedResult do
    @moduledoc """
    Structured result type for embedding transform operations.

    Provides type-safe results for embedding generation operations with
    comprehensive metadata and performance timing information.
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
end
