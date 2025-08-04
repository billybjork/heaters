defmodule Heaters.Repo.Migrations.AddIndexesForEnumFields do
  use Ecto.Migration

  def change do
    # Index for generation_strategy (used in embedding searches)
    create index(:embeddings, [:generation_strategy], name: :idx_embeddings_generation_strategy)
    
    # Composite index for embeddings queries (strategy + clip lookups)
    create index(:embeddings, [:generation_strategy, :clip_id], name: :idx_embeddings_strategy_clip)
    
    # Index for artifact_type + strategy (used in artifact queries)
    create index(:clip_artifacts, [:artifact_type, :strategy], name: :idx_artifacts_type_strategy)
  end
end
