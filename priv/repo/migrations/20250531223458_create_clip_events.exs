defmodule Heaters.Repo.Migrations.CreateClipEvents do
  use Ecto.Migration

  def up do
    create table(:clip_events, primary_key: false) do
      add :id, :serial, primary_key: true

      add :clip_id, references(:clips, name: :fk_clip, on_delete: :restrict, type: :integer),
        null: false

      add :action, :text, null: false
      add :created_at, :timestamptz, null: false, default: fragment("now()")
      add :reviewer_id, :text
      add :event_data, :jsonb

      add :updated_at, :naive_datetime,
        null: false,
        default: fragment("timezone('utc'::text, now())")
    end

    # Using raw SQL for the index with DESC order
    execute """
    CREATE INDEX idx_clip_events_clip_id_created_at
    ON public.clip_events (clip_id, created_at DESC);
    """

    # Comments
    execute "COMMENT ON TABLE public.clip_events IS 'Immutable log of events related to the clip review process.';"

    execute "COMMENT ON COLUMN public.clip_events.clip_id IS 'References the clip the event pertains to.';"

    execute "COMMENT ON COLUMN public.clip_events.action IS 'The specific action taken or committed (e.g., selected_approve, undo, committed_skip).';"

    execute "COMMENT ON COLUMN public.clip_events.created_at IS 'Timestamp when the event was logged.';"

    execute "COMMENT ON COLUMN public.clip_events.reviewer_id IS 'Identifier of the user performing the action (if tracked).';"

    execute "COMMENT ON COLUMN public.clip_events.event_data IS 'Optional JSON blob for additional event context.';"
  end

  def down do
    execute "COMMENT ON COLUMN public.clip_events.event_data IS NULL;"
    execute "COMMENT ON COLUMN public.clip_events.reviewer_id IS NULL;"
    execute "COMMENT ON COLUMN public.clip_events.created_at IS NULL;"
    execute "COMMENT ON COLUMN public.clip_events.action IS NULL;"
    execute "COMMENT ON COLUMN public.clip_events.clip_id IS NULL;"
    execute "COMMENT ON TABLE public.clip_events IS NULL;"

    # Drop the index using its name
    execute "DROP INDEX IF EXISTS public.idx_clip_events_clip_id_created_at;"

    drop table(:clip_events)
  end
end
