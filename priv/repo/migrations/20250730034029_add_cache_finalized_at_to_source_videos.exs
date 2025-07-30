defmodule Heaters.Repo.Migrations.AddCacheFinalizedAtToSourceVideos do
  use Ecto.Migration

  def change do
    alter table(:source_videos) do
      add :cache_finalized_at, :utc_datetime, null: true
    end
  end
end
