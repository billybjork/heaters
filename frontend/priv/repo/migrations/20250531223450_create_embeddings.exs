defmodule Frontend.Repo.Migrations.CreateEmbeddings do
  use Ecto.Migration

  def up do
    create table(:embeddings, primary_key: false) do
      add :id, :serial, primary_key: true
      add :clip_id, references(:clips, on_delete: :delete_all, type: :integer), null: false
      add :embedding, :vector, null: false
      add :model_name, :text, null: false
      add :model_version, :text
      add :generation_strategy, :text, null: false
      add :generated_at, :timestamptz, default: fragment("CURRENT_TIMESTAMP")
      add :embedding_dim, :integer
    end

    create unique_index(:embeddings, [:clip_id, :model_name, :generation_strategy], name: :embeddings_clip_id_model_name_generation_strategy_key)
    create index(:embeddings, [:clip_id, :model_name, :generation_strategy], name: :idx_embeddings_lookup)
  end

  def down do
    drop index(:embeddings, name: :idx_embeddings_lookup)
    drop unique_index(:embeddings, [:clip_id, :model_name, :generation_strategy], name: :embeddings_clip_id_model_name_generation_strategy_key)
    drop table(:embeddings)
  end
end
