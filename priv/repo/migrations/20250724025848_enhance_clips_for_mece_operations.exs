defmodule Heaters.Repo.Migrations.EnhanceClipsForMeceOperations do
  use Ecto.Migration

  @moduledoc """
  Enhance clips table with fields to support MECE operations and user tracking.
  
  Adds ordering, versioning, and user tracking fields to support the enhanced
  virtual clips architecture with cut point operations.
  """

  def up do
    alter table(:clips) do
      # Add MECE validation support
      add :source_video_order, :integer
      add :cut_point_version, :integer, default: 1
      
      # Add user tracking for cut point operations  
      add :created_by_user_id, :integer
      add :last_modified_by_user_id, :integer
    end

    # Populate source_video_order for existing virtual clips
    execute("""
      UPDATE clips 
      SET source_video_order = sub.row_number
      FROM (
        SELECT 
          id,
          ROW_NUMBER() OVER (PARTITION BY source_video_id ORDER BY start_frame) as row_number
        FROM clips 
        WHERE is_virtual = true
      ) sub
      WHERE clips.id = sub.id
    """)

    # Enhanced indexing for MECE operations
    create index(:clips, [:source_video_id, :is_virtual, :source_video_order], 
      where: "is_virtual = true",
      name: :idx_clips_source_video_mece)

    # Add constraint to ensure proper ordering for virtual clips
    create constraint(:clips, :clips_mece_ordering, 
      check: "(is_virtual = false) OR (is_virtual = true AND source_video_order IS NOT NULL)")
  end

  def down do
    drop constraint(:clips, :clips_mece_ordering)
    drop index(:clips, :idx_clips_source_video_mece)

    alter table(:clips) do
      remove :last_modified_by_user_id
      remove :created_by_user_id
      remove :cut_point_version
      remove :source_video_order
    end
  end
end
