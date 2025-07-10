defmodule Heaters.Repo.Migrations.DropReviewEvents do
  use Ecto.Migration

  def up do
    drop table(:review_events)
  end

  def down do
    create table(:review_events, primary_key: false) do
      add :id, :serial, primary_key: true
      add :clip_id, references(:clips, name: :fk_review_events_clip, on_delete: :restrict, type: :integer), null: false
      add :action, :text, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
      add :reviewer_id, :text
      add :event_data, :jsonb
      add :processed_at, :timestamptz
      add :updated_at, :naive_datetime, null: false, default: fragment("timezone('utc'::text, now())")
    end

    # Recreate indexes
    execute "CREATE INDEX idx_review_events_clip_id_inserted_at ON public.review_events (clip_id, inserted_at DESC);"
    execute "CREATE INDEX review_events_processed_at_index ON public.review_events (processed_at);"

    # Recreate comments
    execute "COMMENT ON TABLE public.review_events IS 'Immutable log of events related to the clip review workflow.';"
    execute "COMMENT ON COLUMN public.review_events.clip_id IS 'References the clip the event pertains to.';"
    execute "COMMENT ON COLUMN public.review_events.action IS 'The specific review action taken (e.g., selected_approve, undo, selected_split).';"
    execute "COMMENT ON COLUMN public.review_events.inserted_at IS 'Timestamp when the review event was logged.';"
    execute "COMMENT ON COLUMN public.review_events.reviewer_id IS 'Identifier of the user performing the review action.';"
    execute "COMMENT ON COLUMN public.review_events.event_data IS 'Optional JSON blob for additional review event context.';"
    execute "COMMENT ON COLUMN public.review_events.processed_at IS 'Timestamp when the review event was processed by workers.';"
  end
end
