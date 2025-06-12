defmodule Heaters.Repo.Migrations.CreateClips do
  use Ecto.Migration

  def up do
    create table(:clips, primary_key: false) do
      add :id, :serial, primary_key: true
      # Corrected on_delete to :nilify_all
      add :source_video_id, references(:source_videos, on_delete: :nilify_all, type: :integer)
      add :clip_filepath, :text, null: false
      add :clip_identifier, :text, null: false
      add :start_frame, :integer
      add :end_frame, :integer
      add :start_time_seconds, :float
      add :end_time_seconds, :float
      add :ingest_state, :text, null: false, default: "new"
      add :last_error, :text
      add :retry_count, :integer, null: false, default: 0
      add :reviewed_at, :naive_datetime
      add :keyframed_at, :naive_datetime
      add :embedded_at, :naive_datetime
      add :processing_metadata, :jsonb
      # Corrected on_delete to :nilify_all
      add :grouped_with_clip_id,
          references(:clips,
            name: :fk_clips_grouped_with_clip_id,
            on_delete: :nilify_all,
            type: :integer
          )

      add :action_committed_at, :naive_datetime

      timestamps(type: :timestamptz, default: fragment("now()"))
    end

    create unique_index(:clips, [:clip_filepath], name: :clips_clip_filepath_key)
    create unique_index(:clips, [:clip_identifier], name: :clips_clip_identifier_key)

    create index(:clips, [:action_committed_at],
             name: :clips_action_committed_at_idx,
             where: "action_committed_at IS NOT NULL"
           )

    create index(:clips, [:ingest_state, :reviewed_at, :updated_at, :id],
             name: :clips_review_queue_idx
           )

    create index(:clips, [:ingest_state, :updated_at], name: :idx_clips_cleanup)
    create index(:clips, [:grouped_with_clip_id], name: :idx_clips_grouped_with_clip_id)
    create index(:clips, [:ingest_state], name: :idx_clips_ingest_state)

    create index(:clips, [:ingest_state, :updated_at, :id],
             name: :idx_clips_ingest_state_updated_at_id,
             where: "ingest_state = 'pending_review'::text"
           )

    create index(:clips, [:source_video_id], name: :idx_clips_source_video_id)

    execute """
    CREATE TRIGGER set_timestamp
    BEFORE UPDATE ON public.clips
    FOR EACH ROW
    EXECUTE FUNCTION public.trigger_set_timestamp();
    """

    execute "COMMENT ON COLUMN public.clips.action_committed_at IS 'Timestamp when the final review action state was committed by the Commit Worker, making it eligible for pipeline pickup.';"
  end

  def down do
    execute "COMMENT ON COLUMN public.clips.action_committed_at IS NULL;"
    execute "DROP TRIGGER IF EXISTS set_timestamp ON public.clips;"

    drop index(:clips, name: :idx_clips_source_video_id)
    drop index(:clips, name: :idx_clips_ingest_state_updated_at_id)
    drop index(:clips, name: :idx_clips_ingest_state)
    drop index(:clips, name: :idx_clips_grouped_with_clip_id)
    drop index(:clips, name: :idx_clips_cleanup)
    drop index(:clips, name: :clips_review_queue_idx)
    drop index(:clips, name: :clips_action_committed_at_idx)

    drop unique_index(:clips, [:clip_identifier], name: :clips_clip_identifier_key)
    drop unique_index(:clips, [:clip_filepath], name: :clips_clip_filepath_key)

    drop table(:clips)
  end
end
