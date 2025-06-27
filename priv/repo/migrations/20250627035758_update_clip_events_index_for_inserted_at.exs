defmodule Heaters.Repo.Migrations.UpdateClipEventsIndexForInsertedAt do
  use Ecto.Migration

  def up do
    # Drop the old index that references created_at
    execute "DROP INDEX IF EXISTS public.idx_clip_events_clip_id_created_at;"

    # Create new index using inserted_at instead of created_at
    execute """
    CREATE INDEX idx_clip_events_clip_id_inserted_at
    ON public.clip_events (clip_id, inserted_at DESC);
    """

    # Update the comment to reflect the new field name
    execute "COMMENT ON COLUMN public.clip_events.inserted_at IS 'Timestamp when the event was logged.';"
  end

  def down do
    # Drop the new index
    execute "DROP INDEX IF EXISTS public.idx_clip_events_clip_id_inserted_at;"

    # Recreate the old index (this will fail if created_at doesn't exist, but that's expected in rollback)
    execute """
    CREATE INDEX idx_clip_events_clip_id_created_at
    ON public.clip_events (clip_id, created_at DESC);
    """

    # Restore old comment
    execute "COMMENT ON COLUMN public.clip_events.created_at IS 'Timestamp when the event was logged.';"
  end
end
