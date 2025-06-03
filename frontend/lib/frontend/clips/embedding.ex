defmodule Frontend.Clips.Embedding do
  @moduledoc """
  Ecto schema for the `embeddings` table, storing vector embeddings for each clip.

  Columns:
  - id: primary key
  - clip_id: belongs_to association to `clips`
  - embedding: `vector` (Pgvector.Ecto.Vector)
  - model_name: text
  - model_version: text (nullable)
  - generation_strategy: text
  - generated_at: timestamp with time zone (inserted_at)
  - embedding_dim: integer (nullable)
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Frontend.Clips.Clip
  alias Pgvector.Ecto.Vector

  @type t() :: %__MODULE__{
          id: integer(),
          clip_id: integer(),
          embedding: [float()] | nil,
          model_name: String.t(),
          model_version: String.t() | nil,
          generation_strategy: String.t(),
          embedding_dim: integer() | nil,
          generated_at: DateTime.t(),
          clip: Frontend.Clips.Clip.t() | Ecto.Association.NotLoaded.t()
        }

  schema "embeddings" do
    belongs_to :clip, Clip

    field :embedding, Vector

    field :model_name, :string
    field :model_version, :string
    field :generation_strategy, :string
    field :embedding_dim, :integer

    timestamps(type: :utc_datetime, inserted_at: :generated_at, updated_at: false)
  end

  @required_fields ~w(clip_id model_name generation_strategy embedding)a
  @optional_fields ~w(model_version embedding_dim)a

  @doc false
  def changeset(embedding_struct, attrs) do
    embedding_struct
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:clip_id)

    # Potentially include a cast_embed/validate_embed here
    # e.g., |> Pgvector.Ecto.cast_embed(:embedding)
  end
end
