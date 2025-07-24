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
          is_virtual: boolean(),
          cut_points: map() | nil,
          source_video_order: integer() | nil,
          cut_point_version: integer() | nil,
          created_by_user_id: integer() | nil,
          last_modified_by_user_id: integer() | nil,
          source_video: Heaters.Videos.SourceVideo.t() | Ecto.Association.NotLoaded.t(),
          clip_artifacts:
            [Heaters.Clips.Artifacts.ClipArtifact.t()] | Ecto.Association.NotLoaded.t(),
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
    field(:ingest_state, :string, default: "pending_review")
    field(:last_error, :string)
    field(:retry_count, :integer, default: 0)

    field(:reviewed_at, :naive_datetime)
    field(:keyframed_at, :naive_datetime)
    field(:embedded_at, :naive_datetime)
    field(:processing_metadata, :map)
    field(:grouped_with_clip_id, :integer)
    field(:action_committed_at, :naive_datetime)

    # Virtual clip fields
    field(:is_virtual, :boolean, default: false)
    field(:cut_points, :map)

    # MECE operation fields
    field(:source_video_order, :integer)
    field(:cut_point_version, :integer, default: 1)
    field(:created_by_user_id, :integer)
    field(:last_modified_by_user_id, :integer)

    belongs_to(:source_video, Heaters.Videos.SourceVideo)
    has_many(:clip_artifacts, Heaters.Clips.Artifacts.ClipArtifact)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for updating a clip.
  """
  def changeset(clip, attrs) do
    clip
    |> cast(attrs, [
      :source_video_id,
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
      :action_committed_at,
      :is_virtual,
      :cut_points,
      :source_video_order,
      :cut_point_version,
      :created_by_user_id,
      :last_modified_by_user_id
    ])
    |> validate_required([:source_video_id, :clip_identifier, :ingest_state])
    |> validate_virtual_clip_requirements()
    |> unique_constraint(:clip_identifier, name: "clips_clip_identifier_key")
  end

  # Private helper to validate virtual vs physical clip requirements
  defp validate_virtual_clip_requirements(changeset) do
    is_virtual = get_field(changeset, :is_virtual, false)

    case is_virtual do
      true ->
        # Virtual clips require cut_points but not clip_filepath
        changeset
        |> validate_required([:cut_points])

      false ->
        # Physical clips require clip_filepath but not cut_points
        changeset
        |> validate_required([:clip_filepath])
    end
  end
end
