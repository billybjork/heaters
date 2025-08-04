defmodule Heaters.Repo.Migrations.RemoveVirtualClipConstraints do
  use Ecto.Migration

  def change do
    # Remove all constraints that depend on is_virtual field
    drop constraint(:clips, :clips_filepath_required_when_physical)
    
    # Remove the MECE overlap constraint (depends on is_virtual)
    execute "ALTER TABLE clips DROP CONSTRAINT clips_no_virtual_overlap;"
    
    # Remove virtual clip fields and indexes
    drop index(:clips, [:cut_points], name: :idx_clips_cut_points)
    drop index(:clips, [:source_video_id, :is_virtual], name: :idx_clips_virtual)
    drop index(:clips, [:source_video_id, :start_time_seconds, :end_time_seconds], name: :idx_clips_virtual_time_ranges)
    
    alter table(:clips) do
      remove :is_virtual
      remove :cut_points
      remove :source_video_order
      remove :cut_point_version
    end
  end
end
