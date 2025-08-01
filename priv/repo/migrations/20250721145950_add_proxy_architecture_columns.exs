defmodule Heaters.Repo.Migrations.AddProxyArchitectureColumns do
  use Ecto.Migration

  def up do
    # Add proxy architecture columns to source_videos
    alter table(:source_videos) do
      add :needs_splicing, :boolean, default: true, null: false
      add :proxy_filepath, :text
      add :keyframe_offsets, :jsonb
      add :gold_master_filepath, :text
    end

    # Add virtual clip support to clips table
    alter table(:clips) do
      # Remove NOT NULL constraint from clip_filepath (will be nullable for virtual clips)
      modify :clip_filepath, :text, null: true

      add :is_virtual, :boolean, default: false, null: false
      add :cut_points, :jsonb
    end

    # Add indexes for efficient querying
    create index(:source_videos, [:needs_splicing],
      name: :idx_source_videos_needs_splicing,
      where: "needs_splicing = true"
    )

    create index(:source_videos, [:proxy_filepath],
      name: :idx_source_videos_proxy_filepath,
      where: "proxy_filepath IS NOT NULL"
    )

    create index(:clips, [:source_video_id, :is_virtual],
      name: :idx_clips_virtual,
      where: "is_virtual = true"
    )

    create index(:clips, [:cut_points],
      name: :idx_clips_cut_points,
      using: :gin,
      where: "is_virtual = true"
    )

    # Add constraint: clip_filepath must be present when is_virtual = false (after export)
    create constraint(:clips, :clips_filepath_required_when_physical,
      check: "is_virtual = true OR clip_filepath IS NOT NULL"
    )

    # Add comments for documentation
    execute """
    COMMENT ON COLUMN source_videos.needs_splicing IS 'Whether this video needs scene detection and virtual clip creation. Set to false after scene detection completes.';
    """

    execute """
    COMMENT ON COLUMN source_videos.proxy_filepath IS 'S3 path to the all-I-frame H.264 proxy file used for review UI seeking. Presence indicates preprocessing is complete.';
    """

    execute """
    COMMENT ON COLUMN source_videos.keyframe_offsets IS 'JSON array of byte offsets for keyframes in the proxy file, used for efficient seeking.';
    """

    execute """
    COMMENT ON COLUMN source_videos.gold_master_filepath IS 'S3 path to the lossless FFV1/MKV archival master used for final clip export.';
    """

    execute """
    COMMENT ON COLUMN clips.is_virtual IS 'Whether this clip exists only as cut points (true) or as an encoded file (false). Virtual clips transition to physical during export.';
    """

    execute """
    COMMENT ON COLUMN clips.cut_points IS 'JSON object containing virtual clip boundaries: {start_frame, end_frame, start_time_seconds, end_time_seconds}. Only used for virtual clips.';
    """
  end

  def down do
    # Remove comments
    execute "COMMENT ON COLUMN clips.cut_points IS NULL;"
    execute "COMMENT ON COLUMN clips.is_virtual IS NULL;"
    execute "COMMENT ON COLUMN source_videos.gold_master_filepath IS NULL;"
    execute "COMMENT ON COLUMN source_videos.keyframe_offsets IS NULL;"
    execute "COMMENT ON COLUMN source_videos.proxy_filepath IS NULL;"
    execute "COMMENT ON COLUMN source_videos.needs_splicing IS NULL;"

    # Remove constraint
    drop constraint(:clips, :clips_filepath_required_when_physical)

    # Remove indexes
    drop index(:clips, [:cut_points], name: :idx_clips_cut_points)
    drop index(:clips, [:source_video_id, :is_virtual], name: :idx_clips_virtual)
    drop index(:source_videos, [:proxy_filepath], name: :idx_source_videos_proxy_filepath)
    drop index(:source_videos, [:needs_splicing], name: :idx_source_videos_needs_splicing)

    # Remove columns from clips table
    alter table(:clips) do
      remove :cut_points
      remove :is_virtual

      # Restore NOT NULL constraint on clip_filepath
      modify :clip_filepath, :text, null: false
    end

    # Remove columns from source_videos table
    alter table(:source_videos) do
      remove :gold_master_filepath
      remove :keyframe_offsets
      remove :proxy_filepath
      remove :needs_splicing
    end
  end
end
