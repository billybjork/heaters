defmodule Heaters.Clips.Clip do
  use Heaters.Schema

  @type t() :: %__MODULE__{
          id: integer(),
          clip_filepath: String.t() | nil,
          clip_identifier: String.t() | nil,
          start_frame: integer() | nil,
          end_frame: integer() | nil,
          start_time_seconds: float() | nil,
          end_time_seconds: float() | nil,
          ingest_state: String.t() | nil,
          last_error: String.t() | nil,
          retry_count: integer() | nil,
          reviewed_at: NaiveDateTime.t() | nil,
          keyframed_at: NaiveDateTime.t() | nil,
          embedded_at: NaiveDateTime.t() | nil,
          processing_metadata: map() | nil,
          grouped_with_clip_id: integer() | nil,
          action_committed_at: NaiveDateTime.t() | nil,
          source_video: Heaters.SourceVideos.SourceVideo.t() | Ecto.Association.NotLoaded.t(),
          clip_artifacts:
            [Heaters.Clips.Operations.ClipArtifact.t()] | Ecto.Association.NotLoaded.t(),
          clip_events: [Heaters.Events.ClipEvent.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "clips" do
    field(:clip_filepath, :string)
    field(:clip_identifier, :string)
    field(:start_frame, :integer)
    field(:end_frame, :integer)
    field(:start_time_seconds, :float)
    field(:end_time_seconds, :float)
    field(:ingest_state, :string, default: "new")
    field(:last_error, :string)
    field(:retry_count, :integer, default: 0)

    field(:reviewed_at, :naive_datetime)
    field(:keyframed_at, :naive_datetime)
    field(:embedded_at, :naive_datetime)
    field(:processing_metadata, :map)
    field(:grouped_with_clip_id, :integer)
    field(:action_committed_at, :naive_datetime)

    belongs_to(:source_video, Heaters.SourceVideos.SourceVideo)
    has_many(:clip_artifacts, Heaters.Clips.Operations.ClipArtifact)
    has_many(:clip_events, Heaters.Events.ClipEvent)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for updating a clip.
  """
  def changeset(clip, attrs) do
    clip
    |> cast(attrs, [
      :clip_filepath,
      :clip_identifier,
      :start_frame,
      :end_frame,
      :start_time_seconds,
      :end_time_seconds,
      :ingest_state,
      :last_error,
      :retry_count,
      :reviewed_at,
      :keyframed_at,
      :embedded_at,
      :processing_metadata,
      :grouped_with_clip_id,
      :action_committed_at
    ])
    |> validate_required([:clip_filepath, :clip_identifier, :ingest_state])
  end
end
