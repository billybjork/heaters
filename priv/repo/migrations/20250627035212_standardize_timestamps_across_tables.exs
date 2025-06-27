defmodule Heaters.Repo.Migrations.StandardizeTimestampsAcrossTables do
  use Ecto.Migration

  def up do
    # 1. First, let's standardize the embeddings table to use proper timestamps
    alter table(:embeddings) do
      # Add standard Ecto timestamp columns
      add :inserted_at, :utc_datetime, null: false, default: fragment("timezone('utc'::text, now())")
      add :updated_at, :utc_datetime, null: false, default: fragment("timezone('utc'::text, now())")
    end

    # Copy generated_at to inserted_at for existing data
    execute """
    UPDATE embeddings
    SET inserted_at = timezone('utc'::text, generated_at),
        updated_at = timezone('utc'::text, generated_at)
    WHERE inserted_at IS NULL;
    """

    # Drop the old generated_at column
    alter table(:embeddings) do
      remove :generated_at
    end

    # 2. Standardize clip_events table to use proper timestamps() macro fields
    alter table(:clip_events) do
      # Add proper inserted_at and rename created_at (keep both temporarily for migration)
      add :inserted_at, :utc_datetime, null: false, default: fragment("timezone('utc'::text, now())")
      # Change updated_at to UTC datetime to match our schema
      modify :updated_at, :utc_datetime, null: false, default: fragment("timezone('utc'::text, now())")
    end

    # Copy created_at to inserted_at for existing data
    execute """
    UPDATE clip_events
    SET inserted_at = timezone('utc'::text, created_at)
    WHERE inserted_at IS NULL;
    """

    # Drop the old created_at column now that data is in inserted_at
    alter table(:clip_events) do
      remove :created_at
    end

    # 3. Standardize existing timestamp columns to UTC datetime (to match schemas)
    # Convert source_videos timestamps
    alter table(:source_videos) do
      modify :inserted_at, :utc_datetime, from: :timestamptz
      modify :updated_at, :utc_datetime, from: :timestamptz
    end

    # Convert clips timestamps
    alter table(:clips) do
      modify :inserted_at, :utc_datetime, from: :timestamptz
      modify :updated_at, :utc_datetime, from: :timestamptz
    end

    # Convert clip_artifacts timestamps
    alter table(:clip_artifacts) do
      modify :inserted_at, :utc_datetime, from: :timestamptz
      modify :updated_at, :utc_datetime, from: :timestamptz
    end

    # 4. Update triggers to work with the new UTC datetime format
    execute """
    CREATE OR REPLACE FUNCTION public.trigger_set_timestamp() RETURNS trigger
        LANGUAGE plpgsql
        AS $$
    BEGIN
      NEW.updated_at = timezone('utc'::text, now());
      RETURN NEW;
    END;
    $$;
    """
  end

  def down do
    # This is a comprehensive change - we'll preserve the essential data but may need to restore some original formats

    # 1. Restore embeddings table structure
    alter table(:embeddings) do
      add :generated_at, :timestamptz, null: false, default: fragment("now()")
    end

    # Copy inserted_at back to generated_at
    execute """
    UPDATE embeddings
    SET generated_at = timezone('UTC', inserted_at)::timestamptz
    WHERE generated_at IS NULL;
    """

    alter table(:embeddings) do
      remove :inserted_at
      remove :updated_at
    end

    # 2. Restore clip_events table structure
    alter table(:clip_events) do
      add :created_at, :timestamptz, null: false, default: fragment("now()")
      modify :updated_at, :naive_datetime, null: false, default: fragment("timezone('utc'::text, now())")
    end

    # Copy inserted_at back to created_at
    execute """
    UPDATE clip_events
    SET created_at = timezone('UTC', inserted_at)::timestamptz
    WHERE created_at IS NULL;
    """

    alter table(:clip_events) do
      remove :inserted_at
    end

    # 3. Restore original timestamp types
    alter table(:source_videos) do
      modify :inserted_at, :timestamptz, from: :utc_datetime
      modify :updated_at, :timestamptz, from: :utc_datetime
    end

    alter table(:clips) do
      modify :inserted_at, :timestamptz, from: :utc_datetime
      modify :updated_at, :timestamptz, from: :utc_datetime
    end

    alter table(:clip_artifacts) do
      modify :inserted_at, :timestamptz, from: :utc_datetime
      modify :updated_at, :timestamptz, from: :utc_datetime
    end

    # 4. Restore original trigger function
    execute """
    CREATE OR REPLACE FUNCTION public.trigger_set_timestamp() RETURNS trigger
        LANGUAGE plpgsql
        AS $$
    BEGIN
      NEW.updated_at = NOW();
      RETURN NEW;
    END;
    $$;
    """
  end
end
