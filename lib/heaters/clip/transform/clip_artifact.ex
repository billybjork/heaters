defmodule Heaters.Clip.Transform.ClipArtifact do
  use Heaters.Schema

  @type t() :: %__MODULE__{
          id: integer(),
          artifact_type: String.t() | nil,
          strategy: String.t() | nil,
          tag: String.t() | nil,
          s3_key: String.t() | nil,
          metadata: map() | nil,
          clip: Heaters.Clips.Clip.t() | Ecto.Association.NotLoaded.t(),
          clip_id: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "clip_artifacts" do
    field(:artifact_type, :string)
    field(:strategy, :string)
    field(:tag, :string)
    field(:s3_key, :string)
    field(:metadata, :map)

    belongs_to(:clip, Heaters.Clips.Clip)
    timestamps(type: :utc_datetime)
  end
end
