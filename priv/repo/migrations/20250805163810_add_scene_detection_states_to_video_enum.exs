defmodule Heaters.Repo.Migrations.AddSceneDetectionStatesToVideoEnum do
  use Ecto.Migration

  def change do
    # Remove old constraint
    drop constraint(:source_videos, :ingest_state_must_be_valid)
    
    # Add updated constraint with scene detection states
    create constraint(:source_videos, :ingest_state_must_be_valid,
      check: "ingest_state IN ('new', 'downloading', 'downloaded', 'preprocessing', 'preprocessed', 'detect_scenes', 'scene_detection', 'scene_detection_failed', 'download_failed', 'preprocessing_failed')")
  end
end
