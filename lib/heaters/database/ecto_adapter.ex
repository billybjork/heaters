defmodule Heaters.Database.EctoAdapter do
  @moduledoc """
  Default `Heaters.Database.RepoPort` implementation that simply
  delegates to `Heaters.Repo`.
  """

  @behaviour Heaters.Database.RepoPort
  alias Heaters.Repo

  defdelegate get(schema, id), to: Repo

  defdelegate get!(schema, id), to: Repo
  defdelegate insert(changeset_or_struct), to: Repo
  defdelegate insert_all(schema, rows, opts), to: Repo
  defdelegate update(changeset, opts), to: Repo
  defdelegate update_all(queryable, updates), to: Repo
  defdelegate delete(struct), to: Repo
  defdelegate one(queryable), to: Repo
  defdelegate all(queryable), to: Repo
  defdelegate aggregate(queryable, function, field), to: Repo
  defdelegate one!(queryable), to: Repo
  defdelegate exists?(queryable), to: Repo
  defdelegate query(sql, params), to: Repo
  defdelegate delete_all(queryable), to: Repo
  defdelegate preload(struct_or_structs, assocs), to: Repo
  defdelegate update!(changeset), to: Repo
  defdelegate transaction(fun), to: Repo
  defdelegate rollback(reason), to: Repo
end
