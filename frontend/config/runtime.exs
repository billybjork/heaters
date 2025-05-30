import Config

if System.get_env("PHX_SERVER") do
  config :frontend, FrontendWeb.Endpoint, server: true
end

database_url =
  System.get_env("DATABASE_URL") ||
    raise """
    environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """

config :frontend, :cloudfront_domain, System.fetch_env!("CLOUDFRONT_DOMAIN")

maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

render_db? = String.contains?(database_url, ".render.com")
db_host   = URI.parse(database_url).host |> to_charlist()

# when on Render, point at Alpine’s CA bundle
ssl_opts =
  if render_db? do
    [
      verify: :verify_peer,
      cacertfile: "/etc/ssl/certs/ca-certificates.crt",
      server_name_indication: db_host,
      hostname: db_host
    ]
  else
    []
  end

repo_url =
  if render_db? and not String.contains?(database_url, "sslmode") do
    database_url <> "?sslmode=require"
  else
    database_url
  end

config :frontend, Frontend.Repo,
  url: repo_url,
  ssl: ssl_opts,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  socket_options: maybe_ipv6

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one with: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :frontend, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :frontend, FrontendWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end
