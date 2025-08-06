defmodule Heaters.Repo.Migrations.FixCascadeDeleteForClips do
  use Ecto.Migration

  def up do
    # Drop the existing foreign key constraint
    drop constraint(:clips, "clips_source_video_id_fkey")
    
    # Add the constraint back with cascade delete
    alter table(:clips) do
      modify :source_video_id, references(:source_videos, on_delete: :delete_all, type: :integer)
    end
  end

  def down do
    # Drop the cascade delete constraint
    drop constraint(:clips, "clips_source_video_id_fkey")
    
    # Add the constraint back with nilify_all (original behavior)
    alter table(:clips) do
      modify :source_video_id, references(:source_videos, on_delete: :nilify_all, type: :integer)
    end
  end
end