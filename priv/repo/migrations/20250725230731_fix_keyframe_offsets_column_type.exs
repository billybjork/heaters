defmodule Heaters.Repo.Migrations.FixKeyframeOffsetsColumnType do
  use Ecto.Migration

  def up do
    # Convert keyframe_offsets from jsonb to integer array for proper Ecto compatibility
    alter table(:source_videos) do
      # Remove the existing jsonb column
      remove :keyframe_offsets
      # Add it back as an integer array
      add :keyframe_offsets, {:array, :integer}, default: []
    end

    execute """
    COMMENT ON COLUMN source_videos.keyframe_offsets IS 'Array of byte offsets for keyframes in the proxy file, used for efficient seeking.';
    """
  end

  def down do
    alter table(:source_videos) do
      remove :keyframe_offsets
      add :keyframe_offsets, :jsonb
    end

    execute """
    COMMENT ON COLUMN source_videos.keyframe_offsets IS 'JSON array of byte offsets for keyframes in the proxy file, used for efficient seeking.';
    """
  end
end