defmodule Heaters.Repo.Migrations.RemoveLegacyVirtualClipsCreatedState do
  use Ecto.Migration

  def change do
    # Remove old constraint
    drop constraint(:source_videos, :ingest_state_must_be_valid)

    # Add updated constraint without virtual_clips_created
    create constraint(:source_videos, :ingest_state_must_be_valid,
      check: "ingest_state IN ('new', 'downloading', 'downloaded', 'preprocessing', 'preprocessed', 'detect_scenes', 'download_failed', 'preprocessing_failed')")
  end
end
