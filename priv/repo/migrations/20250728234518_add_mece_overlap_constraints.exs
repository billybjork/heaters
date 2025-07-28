defmodule Heaters.Repo.Migrations.AddMeceOverlapConstraints do
  use Ecto.Migration

  @moduledoc """
  Add PostgreSQL EXCLUDE constraints to prevent overlapping virtual clips.
  
  This migration implements database-level MECE (Mutually Exclusive, Collectively Exhaustive)
  validation for virtual clips using PostgreSQL's EXCLUDE constraint with GIST indexes.
  
  The constraint prevents two virtual clips from the same source video from having
  overlapping time ranges, ensuring data integrity at the database level.
  """

  def up do
    # Enable btree_gist extension for range operations
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist;"
    
    # Add EXCLUDE constraint to prevent overlapping time ranges for virtual clips
    # within the same source video
    execute """
    ALTER TABLE clips
      ADD CONSTRAINT clips_no_virtual_overlap
      EXCLUDE USING gist (
        source_video_id WITH =,
        numrange(
          start_time_seconds::numeric,
          end_time_seconds::numeric,
          '[)'
        ) WITH &&
      )
      WHERE (is_virtual = true);
    """

    # Add supporting index for efficient MECE validation queries
    create index(:clips, [:source_video_id, :start_time_seconds, :end_time_seconds],
      where: "is_virtual = true",
      name: :idx_clips_virtual_time_ranges
    )

    # Add comments for documentation
    execute """
    COMMENT ON CONSTRAINT clips_no_virtual_overlap ON clips IS 
    'Ensures virtual clips from the same source video do not have overlapping time ranges. Uses PostgreSQL EXCLUDE with GIST for database-level MECE validation.';
    """
  end

  def down do
    # Remove comment
    execute """
    COMMENT ON CONSTRAINT clips_no_virtual_overlap ON clips IS NULL;
    """

    # Remove supporting index
    drop index(:clips, :idx_clips_virtual_time_ranges)

    # Remove EXCLUDE constraint
    execute "ALTER TABLE clips DROP CONSTRAINT clips_no_virtual_overlap;"
    
    # Note: We don't drop btree_gist extension as other parts of the system may use it
  end
end