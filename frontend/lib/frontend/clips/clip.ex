defmodule Frontend.Clips.Clip do
  use Frontend.Clips.Schema

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
          source_video: Frontend.Clips.SourceVideo.t() | Ecto.Association.NotLoaded.t(),
          clip_artifacts: [Frontend.Clips.ClipArtifact.t()] | Ecto.Association.NotLoaded.t(),
          clip_events: [Frontend.Clips.ClipEvent.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "clips" do
    field :clip_filepath, :string
    field :clip_identifier, :string
    field :start_frame, :integer
    field :end_frame, :integer
    field :start_time_seconds, :float
    field :end_time_seconds, :float
    field :ingest_state, :string, default: "new"
    field :last_error, :string
    field :retry_count, :integer, default: 0

    field :reviewed_at, :naive_datetime
    field :keyframed_at, :naive_datetime
    field :embedded_at, :naive_datetime
    field :processing_metadata, :map
    field :grouped_with_clip_id, :integer
    field :action_committed_at, :naive_datetime

    belongs_to :source_video, Frontend.Clips.SourceVideo
    has_many :clip_artifacts, Frontend.Clips.ClipArtifact
    has_many :clip_events, Frontend.Clips.ClipEvent

    timestamps(type: :utc_datetime)
  end
end
