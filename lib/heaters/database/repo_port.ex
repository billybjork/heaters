defmodule Heaters.Database.RepoPort do
  @moduledoc """
  Behaviour defining the minimal database operations required by the
  domain.  The default implementation delegates to `Heaters.Repo`, but
  tests or alternative back-ends can provide their own adapter.
  """

  @callback get(module(), term()) :: struct() | nil
  @callback get!(module(), term()) :: struct()
  @callback insert(struct()) :: {:ok, struct()} | {:error, term()}
  @callback insert_all(module(), [map()], Keyword.t()) :: {non_neg_integer(), [map()]}
  @callback update(Ecto.Changeset.t(), Keyword.t()) :: {:ok, struct()} | {:error, term()}
  @callback update_all(Ecto.Queryable.t(), Keyword.t()) :: {non_neg_integer(), term()}
  @callback delete(struct()) :: {:ok, struct()} | {:error, term()}
  @callback one(Ecto.Queryable.t()) :: any()
  @callback all(Ecto.Queryable.t()) :: [any()]
  @callback aggregate(Ecto.Queryable.t(), atom(), atom()) :: any()
  @callback one(Ecto.Queryable.t()) :: any()
  @callback one!(Ecto.Queryable.t()) :: any()
  @callback exists?(Ecto.Queryable.t()) :: boolean()
  @callback query(String.t(), [any()]) :: {:ok, %{rows: [[any()]]}} | {:error, any()}
  @callback delete_all(Ecto.Queryable.t()) :: {non_neg_integer(), any()}
  @callback update_all(Ecto.Queryable.t(), Keyword.t()) :: {non_neg_integer(), any()}
  @callback preload(struct() | [struct()], atom() | [atom()]) :: struct() | [struct()]
  @callback update!(struct()) :: struct()
  @callback transaction((-> any())) :: {:ok, any()} | {:error, any()}
  @callback rollback(any()) :: no_return()
end
