defmodule Frontend.Clips.ClipEvent do
  use Frontend.Clips.Schema

  @type t() :: %__MODULE__{
          id: integer(),
          action: String.t() | nil,
          reviewer_id: String.t() | nil,
          event_data: map() | nil,
          clip_id: integer(),
          clip: Frontend.Clips.Clip.t() | Ecto.Association.NotLoaded.t(),
          created_at: DateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  schema "clip_events" do
    field :action, :string
    field :reviewer_id, :string
    field :event_data, :map

    belongs_to :clip, Frontend.Clips.Clip

    field :created_at, :utc_datetime
    field :updated_at, :naive_datetime
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:clip_id, :action, :reviewer_id, :event_data])
    |> validate_required([:clip_id, :action])
  end
end
