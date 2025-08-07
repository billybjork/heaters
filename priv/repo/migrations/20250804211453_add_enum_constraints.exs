defmodule Heaters.Repo.Migrations.AddEnumConstraints do
  use Ecto.Migration

  def change do
    # Add constraints for artifact_type enum
    create constraint(:clip_artifacts, :artifact_type_must_be_valid,
      check: "artifact_type IN ('keyframe')")

    # Add constraints for video ingest_state enum
    create constraint(:source_videos, :ingest_state_must_be_valid,
      check: "ingest_state IN ('new', 'downloading', 'downloaded', 'preprocessing', 'preprocessed', 'detect_scenes', 'virtual_clips_created', 'download_failed', 'preprocessing_failed')")

    # Add constraints for clip ingest_state enum
    create constraint(:clips, :ingest_state_must_be_valid,
      check: "ingest_state IN ('pending_review', 'review_approved', 'review_skipped', 'review_archived', 'exporting', 'exported', 'export_failed', 'keyframing', 'keyframed', 'keyframe_failed', 'embedding', 'embedded', 'embedding_failed')")
  end
end
