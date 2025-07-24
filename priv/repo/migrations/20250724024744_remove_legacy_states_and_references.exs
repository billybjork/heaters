defmodule Heaters.Repo.Migrations.RemoveLegacyStatesAndReferences do
  use Ecto.Migration

  @moduledoc """
  Clean up legacy database references from merge/split/splice/sprite concepts.
  
  This migration removes legacy states and prepares the database for the 
  enhanced virtual clips architecture.
  """

  def up do
    # Remove sprite artifacts
    execute("DELETE FROM clip_artifacts WHERE artifact_type = 'sprite_sheet'")
    
    # Update clips in legacy states to appropriate virtual clip states
    # Note: This assumes clips have been migrated to virtual clips already
    execute("""
      UPDATE clips 
      SET ingest_state = 'pending_review' 
      WHERE ingest_state IN ('spliced', 'generating_sprite', 'sprite_failed')
    """)
    
    # Remove legacy spliced_at column from source_videos if it exists
    alter table(:source_videos) do
      remove_if_exists(:spliced_at, :utc_datetime)
    end
    
    # Add comment for future reference
    execute("COMMENT ON TABLE clips IS 'Enhanced virtual clips support - legacy merge/split/splice/sprite removed'")
  end

  def down do
    # This migration is not easily reversible since we're removing legacy concepts entirely
    # The "down" would require restoring old code modules that we've deleted
    execute("COMMENT ON TABLE clips IS NULL")
    
    # Re-add spliced_at column if needed for rollback
    alter table(:source_videos) do
      add_if_not_exists(:spliced_at, :utc_datetime)
    end
  end
end