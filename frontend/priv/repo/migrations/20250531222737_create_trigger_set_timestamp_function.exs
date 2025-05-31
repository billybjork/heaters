defmodule Frontend.Repo.Migrations.CreateTriggerSetTimestampFunction do
  use Ecto.Migration

  def up do
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

  def down do
    execute "DROP FUNCTION IF EXISTS public.trigger_set_timestamp();"
  end
end
