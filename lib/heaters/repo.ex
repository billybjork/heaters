defmodule Heaters.Repo do
  use Ecto.Repo,
    otp_app: :heaters,
    adapter: Ecto.Adapters.Postgres
end
