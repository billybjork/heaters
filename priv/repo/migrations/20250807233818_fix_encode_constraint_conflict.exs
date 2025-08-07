defmodule Heaters.Repo.Migrations.FixEncodeConstraintConflict do
  use Ecto.Migration

  def up do
    # Remove ALL possible constraint names that might exist
    execute "ALTER TABLE source_videos DROP CONSTRAINT IF EXISTS ingest_state_must_be_valid"
    execute "ALTER TABLE source_videos DROP CONSTRAINT IF EXISTS source_videos_ingest_state_check"
    execute "ALTER TABLE source_videos DROP CONSTRAINT IF EXISTS source_videos_ingest_state_must_be_valid"
    
    # Update existing rows from preprocessing* → encoding*
    execute "UPDATE source_videos SET ingest_state = 'encoding' WHERE ingest_state = 'preprocessing'"
    execute "UPDATE source_videos SET ingest_state = 'encoded' WHERE ingest_state = 'preprocessed'"
    execute "UPDATE source_videos SET ingest_state = 'encoding_failed' WHERE ingest_state = 'preprocessing_failed'"

    # Add the correct constraint with updated values
    execute """
    ALTER TABLE source_videos
    ADD CONSTRAINT ingest_state_must_be_valid
    CHECK (ingest_state IN (
      'new', 'downloading', 'downloaded', 'download_failed',
      'encoding', 'encoded', 'encoding_failed',
      'detect_scenes', 'detecting_scenes', 'detect_scenes_failed'
    ))
    """
  end

  def down do
    # Remove current constraint
    execute "ALTER TABLE source_videos DROP CONSTRAINT IF EXISTS ingest_state_must_be_valid"

    # Revert encoding* back to preprocessing*
    execute "UPDATE source_videos SET ingest_state = 'preprocessing' WHERE ingest_state = 'encoding'"
    execute "UPDATE source_videos SET ingest_state = 'preprocessed' WHERE ingest_state = 'encoded'"
    execute "UPDATE source_videos SET ingest_state = 'preprocessing_failed' WHERE ingest_state = 'encoding_failed'"

    # Restore previous constraint with preprocessing values
    execute """
    ALTER TABLE source_videos
    ADD CONSTRAINT ingest_state_must_be_valid
    CHECK (ingest_state IN (
      'new', 'downloading', 'downloaded', 'download_failed',
      'preprocessing', 'preprocessed', 'preprocessing_failed',
      'detect_scenes', 'detecting_scenes', 'detect_scenes_failed'
    ))
    """
  end
end