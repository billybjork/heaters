defmodule Heaters.Repo.Migrations.AddArchivedStateToClipEnum do
  use Ecto.Migration

  def change do
    # Remove old constraint
    drop constraint(:clips, :ingest_state_must_be_valid)
    
    # Add updated constraint with archived state
    create constraint(:clips, :ingest_state_must_be_valid,
      check: "ingest_state IN ('pending_review', 'review_approved', 'review_skipped', 'review_archived', 'archived', 'exporting', 'exported', 'export_failed', 'keyframing', 'keyframed', 'keyframe_failed', 'embedding', 'embedded', 'embedding_failed')")
  end
end
