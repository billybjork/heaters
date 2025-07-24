defmodule Heaters.Repo.Migrations.RenameGoldMasterToMaster do
  use Ecto.Migration

  def change do
    rename table(:source_videos), :gold_master_filepath, to: :master_filepath
  end
end
