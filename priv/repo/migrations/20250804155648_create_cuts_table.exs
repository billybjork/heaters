defmodule Heaters.Repo.Migrations.CreateCutsTable do
  use Ecto.Migration

  def change do
    create table(:cuts) do
      add :frame_number, :integer, null: false
      add :time_seconds, :float, null: false
      add :source_video_id, references(:source_videos, on_delete: :delete_all), null: false
      add :created_by_user_id, :integer, null: true
      add :operation_metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    # Ensure unique cuts per source video and frame
    create unique_index(:cuts, [:source_video_id, :frame_number], 
      name: "cuts_source_video_id_frame_number_index")

    # Index for efficient queries by source video
    create index(:cuts, [:source_video_id])

    # Index for temporal ordering
    create index(:cuts, [:source_video_id, :time_seconds])
  end
end
