defmodule Heaters.Repo.Migrations.UpgradeObanForUniqueConstraints do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 12)
  end

  def down do
    Oban.Migration.down(version: 11)
  end
end
