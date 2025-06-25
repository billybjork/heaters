defmodule Heaters.Events.ClipEvent do
  use Heaters.Schema

  @type t() :: %__MODULE__{
          id: integer(),
          action: String.t() | nil,
          reviewer_id: String.t() | nil,
          event_data: map() | nil,
          clip_id: integer(),
          clip: Heaters.Clips.Clip.t() | Ecto.Association.NotLoaded.t(),
          created_at: DateTime.t(),
          updated_at: NaiveDateTime.t(),
          processed_at: DateTime.t() | nil
        }

  schema "clip_events" do
    field(:action, :string)
    field(:reviewer_id, :string)
    field(:event_data, :map)
    field(:processed_at, :utc_datetime)

    belongs_to(:clip, Heaters.Clips.Clip)

    field(:created_at, :utc_datetime)
    field(:updated_at, :naive_datetime)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:clip_id, :action, :reviewer_id, :event_data, :processed_at])
    |> validate_required([:clip_id, :action])
  end
end
