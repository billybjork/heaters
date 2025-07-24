defmodule Heaters.Repo.Migrations.CreateCutPointOperationsTable do
  use Ecto.Migration

  @moduledoc """
  Create cut_point_operations table for audit trail of all cut point operations.
  
  This table tracks all add/remove/move cut point operations performed during
  virtual clip review, providing complete audit trail and operation history.
  """

  def change do
    create table(:cut_point_operations) do
      add :source_video_id, references(:source_videos, on_delete: :delete_all), null: false
      add :operation_type, :string, null: false  # 'add', 'remove', 'move'
      add :frame_number, :integer, null: false
      add :old_frame_number, :integer  # For move operations
      add :user_id, :integer, null: false
      add :affected_clip_ids, {:array, :integer}  # Array of clip IDs affected
      add :metadata, :map
      
      timestamps(type: :utc_datetime)
    end

    create index(:cut_point_operations, [:source_video_id, :inserted_at])
    create index(:cut_point_operations, [:operation_type])
    create index(:cut_point_operations, [:user_id])
    create index(:cut_point_operations, [:frame_number])
    
    # Add constraint to ensure operation_type is valid
    create constraint(:cut_point_operations, :valid_operation_type, 
      check: "operation_type IN ('add', 'remove', 'move')")
  end
end
