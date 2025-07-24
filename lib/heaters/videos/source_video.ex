defmodule Heaters.Videos.SourceVideo do
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
          needs_splicing: boolean(),
          proxy_filepath: String.t() | nil,
          keyframe_offsets: list() | nil,
          master_filepath: String.t() | nil,
          downloaded_at: DateTime.t() | nil,
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
    field(:needs_splicing, :boolean, default: true)
    field(:proxy_filepath, :string)
    field(:keyframe_offsets, {:array, :integer})
    field(:master_filepath, :string)
    field(:downloaded_at, :utc_datetime)
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
      :original_url,
      :needs_splicing,
      :proxy_filepath,
      :keyframe_offsets,
      :master_filepath,
      :downloaded_at
    ])
    |> validate_required([:ingest_state])
  end
end
