defmodule Heaters.Repo.Migrations.UpdateSceneDetectionEnumConsistency do
  use Ecto.Migration

  def up do
    # Update any existing records that might have the old enum values first
    execute "UPDATE source_videos SET ingest_state = 'detecting_scenes' WHERE ingest_state = 'scene_detection'"
    execute "UPDATE source_videos SET ingest_state = 'detect_scenes_failed' WHERE ingest_state = 'scene_detection_failed'"

    # Update the correct CHECK constraint (ingest_state_must_be_valid) to use consistent enum naming
    execute """
    ALTER TABLE source_videos 
    DROP CONSTRAINT IF EXISTS ingest_state_must_be_valid
    """

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

  def down do
    # Revert constraint to old naming first
    execute """
    ALTER TABLE source_videos 
    DROP CONSTRAINT IF EXISTS ingest_state_must_be_valid
    """

    execute """
    ALTER TABLE source_videos 
    ADD CONSTRAINT ingest_state_must_be_valid 
    CHECK (ingest_state IN (
      'new', 'downloading', 'downloaded', 'download_failed',
      'preprocessing', 'preprocessed', 'preprocessing_failed',
      'detect_scenes', 'scene_detection', 'scene_detection_failed'
    ))
    """

    # Revert to old enum values in data
    execute "UPDATE source_videos SET ingest_state = 'scene_detection' WHERE ingest_state = 'detecting_scenes'"
    execute "UPDATE source_videos SET ingest_state = 'scene_detection_failed' WHERE ingest_state = 'detect_scenes_failed'"
  end
end