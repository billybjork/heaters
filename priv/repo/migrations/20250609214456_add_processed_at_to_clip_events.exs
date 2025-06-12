defmodule Heaters.Repo.Migrations.AddProcessedAtToClipEvents do
  use Ecto.Migration

  def change do
    alter table(:clip_events) do
      add :processed_at, :timestamptz
    end

    create index(:clip_events, [:processed_at], where: "processed_at IS NULL")
  end
end
