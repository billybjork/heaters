defmodule Frontend.Repo.Migrations.CreateClipArtifacts do
  use Ecto.Migration

  def up do
    create table(:clip_artifacts, primary_key: false) do
      add :id, :serial, primary_key: true
      add :clip_id, references(:clips, on_delete: :delete_all, type: :integer), null: false
      add :artifact_type, :text, null: false
      add :strategy, :text
      add :tag, :text
      add :s3_key, :text, null: false
      add :metadata, :jsonb

      # Use Ecto's default inserted_at and updated_at
      timestamps(type: :timestamptz, default: fragment("now()"))
    end

    create unique_index(:clip_artifacts, [:s3_key], name: :clip_artifacts_s3_key_key)
    create unique_index(:clip_artifacts, [:clip_id, :artifact_type, :strategy, :tag], name: :uq_clip_artifact_identity)

    create index(:clip_artifacts, [:clip_id], name: :idx_clip_artifacts_clip_id)
    create index(:clip_artifacts, [:clip_id, :artifact_type], name: :idx_clip_artifacts_clip_id_type)
    create index(:clip_artifacts, [:clip_id, :artifact_type, :tag], name: :idx_clip_artifacts_representative_tag, where: "tag = 'representative'::text")
    create index(:clip_artifacts, [:clip_id, :artifact_type, :strategy], name: :idx_clip_artifacts_type_strategy)
  end

  def down do
    drop index(:clip_artifacts, name: :idx_clip_artifacts_type_strategy)
    drop index(:clip_artifacts, name: :idx_clip_artifacts_representative_tag)
    drop index(:clip_artifacts, name: :idx_clip_artifacts_clip_id_type)
    drop index(:clip_artifacts, name: :idx_clip_artifacts_clip_id)

    drop unique_index(:clip_artifacts, [:clip_id, :artifact_type, :strategy, :tag], name: :uq_clip_artifact_identity)
    drop unique_index(:clip_artifacts, [:s3_key], name: :clip_artifacts_s3_key_key)

    drop table(:clip_artifacts)
  end
end
