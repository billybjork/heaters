defmodule Heaters.Video.Intake.SourceVideo do
  use Heaters.Schema

  @type t() :: %__MODULE__{
          id: integer(),
          filepath: String.t() | nil,
          duration_seconds: float() | nil,
          fps: float() | nil,
          width: integer() | nil,
          height: integer() | nil,
          published_date: Date.t() | nil,
          title: String.t() | nil,
          ingest_state: String.t(),
          last_error: String.t() | nil,
          retry_count: integer(),
          original_url: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "source_videos" do
    field(:filepath, :string)
    field(:duration_seconds, :float)
    field(:fps, :float)
    field(:width, :integer)
    field(:height, :integer)
    field(:published_date, :date)
    field(:title, :string)
    field(:ingest_state, :string, default: "new")
    field(:last_error, :string)
    field(:retry_count, :integer, default: 0)
    field(:original_url, :string)
    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for updating a source video.
  """
  def changeset(source_video, attrs) do
    source_video
    |> cast(attrs, [
      :filepath,
      :duration_seconds,
      :fps,
      :width,
      :height,
      :published_date,
      :title,
      :ingest_state,
      :last_error,
      :retry_count,
      :original_url
    ])
    |> validate_required([:ingest_state])
  end
end
