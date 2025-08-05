defmodule Heaters.Repo.Migrations.RenameCacheFinalizedAtToCachePersistedAt do
  use Ecto.Migration

  def change do
    rename table(:source_videos), :cache_finalized_at, to: :cache_persisted_at
  end
end
