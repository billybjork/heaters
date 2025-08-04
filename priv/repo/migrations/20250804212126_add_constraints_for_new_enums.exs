defmodule Heaters.Repo.Migrations.AddConstraintsForNewEnums do
  use Ecto.Migration

  def change do
    # Add constraint for artifact strategy enum
    create constraint(:clip_artifacts, :strategy_must_be_valid,
      check: "strategy IN ('multi', 'midpoint', 'single')")

    # Add constraint for embedding generation_strategy enum  
    create constraint(:embeddings, :generation_strategy_must_be_valid,
      check: "generation_strategy IN ('keyframe_multi_avg', 'keyframe_multi', 'keyframe_single')")
  end
end
