defmodule Heaters.Repo.Migrations.RenameClipEventsToReviewEvents do
  use Ecto.Migration

  def up do
    # Rename the table
    execute "ALTER TABLE clip_events RENAME TO review_events;"

    # Update foreign key constraint name for clarity
    execute "ALTER TABLE review_events RENAME CONSTRAINT fk_clip TO fk_review_events_clip;"

    # Rename indexes to reflect new table name
    execute "ALTER INDEX idx_clip_events_clip_id_inserted_at RENAME TO idx_review_events_clip_id_inserted_at;"
    execute "ALTER INDEX clip_events_processed_at_index RENAME TO review_events_processed_at_index;"

    # Update table and column comments
    execute "COMMENT ON TABLE public.review_events IS 'Immutable log of events related to the clip review workflow.';"
    execute "COMMENT ON COLUMN public.review_events.clip_id IS 'References the clip the event pertains to.';"
    execute "COMMENT ON COLUMN public.review_events.action IS 'The specific review action taken (e.g., selected_approve, undo, selected_split).';"
    execute "COMMENT ON COLUMN public.review_events.inserted_at IS 'Timestamp when the review event was logged.';"
    execute "COMMENT ON COLUMN public.review_events.reviewer_id IS 'Identifier of the user performing the review action.';"
    execute "COMMENT ON COLUMN public.review_events.event_data IS 'Optional JSON blob for additional review event context.';"
    execute "COMMENT ON COLUMN public.review_events.processed_at IS 'Timestamp when the review event was processed by workers.';"
  end

  def down do
    # Rename table back
    execute "ALTER TABLE review_events RENAME TO clip_events;"

    # Rename constraint back
    execute "ALTER TABLE clip_events RENAME CONSTRAINT fk_review_events_clip TO fk_clip;"

    # Rename indexes back
    execute "ALTER INDEX idx_review_events_clip_id_inserted_at RENAME TO idx_clip_events_clip_id_inserted_at;"
    execute "ALTER INDEX review_events_processed_at_index RENAME TO clip_events_processed_at_index;"

    # Restore original comments
    execute "COMMENT ON TABLE public.clip_events IS 'Immutable log of events related to the clip review process.';"
    execute "COMMENT ON COLUMN public.clip_events.clip_id IS 'References the clip the event pertains to.';"
    execute "COMMENT ON COLUMN public.clip_events.action IS 'The specific action taken or committed (e.g., selected_approve, undo, committed_skip).';"
    execute "COMMENT ON COLUMN public.clip_events.inserted_at IS 'Timestamp when the event was logged.';"
    execute "COMMENT ON COLUMN public.clip_events.reviewer_id IS 'Identifier of the user performing the action (if tracked).';"
    execute "COMMENT ON COLUMN public.clip_events.event_data IS 'Optional JSON blob for additional event context.';"
    execute "COMMENT ON COLUMN public.clip_events.processed_at IS 'Timestamp when the event was processed.';"
  end
end
