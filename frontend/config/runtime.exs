import Config

# Enable the server for releases / Docker if PHX_SERVER=true
if System.get_env("PHX_SERVER") do
  config :frontend, FrontendWeb.Endpoint, server: true
end

# ───────────────────────────────────────────
#  Common runtime config (all envs)
# ───────────────────────────────────────────
database_url =
  System.get_env("DATABASE_URL") ||
    raise """
    environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """

config :frontend, :cloudfront_domain, System.fetch_env!("CLOUDFRONT_DOMAIN")

maybe_ipv6 =
  if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

# Detect Render-hosted Postgres (requires SSL)
render_db? = String.contains?(database_url, ".render.com")

# ── SSL options ──
# On Render: disable peer/hostname verification (to avoid bad_cert),
# but supply the CA bundle so Phoenix stops warning.
ssl_opts =
  if render_db? do
    [
      verify: :verify_none,
      cacertfile: "/etc/ssl/certs/ca-certificates.crt"
    ]
  else
    []
  end

config :frontend, Frontend.Repo,
  url:
    (if render_db? and not String.contains?(database_url, "sslmode") do
       database_url <> "?sslmode=require"
     else
       database_url
     end),
  ssl: render_db?,
  ssl_opts: ssl_opts,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  socket_options: maybe_ipv6

# ───────────────────────────────────────────
#  Production-only settings
# ───────────────────────────────────────────
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

  # If you later need full HTTPS termination inside the container,
  # uncomment and adjust the block below:
  #
  # config :frontend, FrontendWeb.Endpoint,
  #   https: [
  #     port: 443,
  #     cipher_suite: :strong,
  #     keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #     certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #   ],
  #   force_ssl: [hsts: true]
end
