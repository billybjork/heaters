defmodule Heaters.Repo.Migrations.AddVectorExtension do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector;"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS vector;"
  end
end
