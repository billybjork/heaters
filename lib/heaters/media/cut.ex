defmodule Heaters.Media.Cut do
  @moduledoc """
  Core domain entity representing cut points in source videos.

  Cuts are the source of truth for video segmentation. They define the boundaries
  where one segment ends and another begins. Clips are derived entities representing
  the segments between cuts.

  ## Domain Logic

  - Cuts are immutable once created (operations create new cuts, archive old ones)
  - Cuts naturally order by frame_number for temporal sequencing
  - Scene detection creates initial cuts; human review adds/removes/moves cuts
  - All cut operations maintain MECE (Mutually Exclusive, Collectively Exhaustive) properties

  ## Cut Operations

  - **Add Cut**: Creates new boundary → splits existing segment
  - **Remove Cut**: Eliminates boundary → merges adjacent segments
  - **Move Cut**: Adjusts boundary → resizes adjacent segments

  All operations are handled through `Heaters.Media.Cuts.Operations` with
  declarative rules defined in `Heaters.Media.Cuts`.
  """

  use Heaters.Schema

  @type t :: %__MODULE__{
          id: integer(),
          frame_number: integer(),
          time_seconds: float(),
          source_video_id: integer(),
          created_by_user_id: integer() | nil,
          operation_metadata: map() | nil,
          source_video: Heaters.Media.Video.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "cuts" do
    field(:frame_number, :integer)
    field(:time_seconds, :float)
    field(:created_by_user_id, :integer)
    field(:operation_metadata, :map)

    belongs_to(:source_video, Heaters.Media.Video)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a cut.

  ## Required Fields
  - `:source_video_id`: The source video this cut belongs to
  - `:frame_number`: Frame number where the cut occurs (must be positive)
  - `:time_seconds`: Time in seconds where the cut occurs (must be positive)

  ## Optional Fields
  - `:created_by_user_id`: User who created this cut (nil for system-generated cuts)
  - `:operation_metadata`: Additional metadata about the cut creation operation
  """
  def changeset(cut, attrs) do
    cut
    |> cast(attrs, [
      :source_video_id,
      :frame_number,
      :time_seconds,
      :created_by_user_id,
      :operation_metadata
    ])
    |> validate_required([:source_video_id, :frame_number, :time_seconds])
    |> validate_number(:frame_number, greater_than: 0)
    |> validate_number(:time_seconds, greater_than_or_equal_to: 0.0)
    |> unique_constraint([:source_video_id, :frame_number],
      name: "cuts_source_video_id_frame_number_index"
    )
  end
end
