defmodule Heaters.Media.VirtualClip.CutPointOperation do
  @moduledoc """
  Schema for cut point operations audit trail.

  Tracks all add/remove/move operations on virtual clip cut points
  for audit and debugging purposes.
  """

  use Heaters.Schema

  @type t :: %__MODULE__{
          id: integer(),
          source_video_id: integer(),
          operation_type: String.t(),
          frame_number: integer(),
          old_frame_number: integer() | nil,
          user_id: integer(),
          affected_clip_ids: [integer()],
          metadata: map(),
          source_video: Heaters.Media.Video.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "cut_point_operations" do
    field(:operation_type, :string)
    field(:frame_number, :integer)
    field(:old_frame_number, :integer)
    field(:user_id, :integer)
    field(:affected_clip_ids, {:array, :integer})
    field(:metadata, :map)

    belongs_to(:source_video, Heaters.Media.Video)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :source_video_id,
      :operation_type,
      :frame_number,
      :old_frame_number,
      :user_id,
      :affected_clip_ids,
      :metadata
    ])
    |> validate_required([:source_video_id, :operation_type, :frame_number, :user_id])
    |> validate_inclusion(:operation_type, ["add", "remove", "move"])
  end
end
