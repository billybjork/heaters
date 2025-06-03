defmodule Frontend.Repo.Migrations.CreateSourceVideos do
  use Ecto.Migration

  def up do
    create table(:source_videos, primary_key: false) do
      add :id, :serial, primary_key: true
      add :filepath, :text
      add :duration_seconds, :float
      add :fps, :float
      add :width, :integer
      add :height, :integer
      add :published_date, :date
      add :web_scraped, :boolean, default: false

      # created_at and updated_at are handled by timestamps below, matching the schema's timestamptz and defaults
      add :title, :text, null: false
      add :ingest_state, :text, null: false, default: "new"
      add :last_error, :text
      add :retry_count, :integer, null: false, default: 0
      add :downloaded_at, :timestamptz
      add :spliced_at, :timestamptz
      add :original_url, :text

      # For created_at and updated_at
      timestamps(type: :timestamptz, default: fragment("now()"))
    end

    create unique_index(:source_videos, [:filepath], name: :source_videos_filepath_key)
    # Standard index for title
    create index(:source_videos, [:title], name: :idx_source_videos_identifier)
    create index(:source_videos, [:ingest_state], name: :idx_source_videos_ingest_state)

    # For text_pattern_ops, raw SQL is needed as Ecto's index builder doesn't directly support operator classes.
    execute """
    CREATE INDEX idx_source_videos_title_pattern_ops ON public.source_videos USING btree (title text_pattern_ops);
    """

    # Trigger for updated_at (matches the one for clips)
    execute """
    CREATE TRIGGER set_timestamp
    BEFORE UPDATE ON public.source_videos
    FOR EACH ROW
    EXECUTE FUNCTION public.trigger_set_timestamp();
    """

    # Comments (Optional but good for completeness)
    # No table comments for source_videos in the dump
  end

  def down do
    execute "DROP TRIGGER IF EXISTS set_timestamp ON public.source_videos;"
    # Drop indexes in reverse order of creation (or Ecto handles names automatically)
    execute "DROP INDEX IF EXISTS idx_source_videos_title_pattern_ops;"
    drop index(:source_videos, [:ingest_state], name: :idx_source_videos_ingest_state)
    drop index(:source_videos, [:title], name: :idx_source_videos_identifier)
    drop unique_index(:source_videos, [:filepath], name: :source_videos_filepath_key)
    drop table(:source_videos)
  end
end
