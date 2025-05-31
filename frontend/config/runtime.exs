import Config

# Configure phoenix_html to mòve CSRF tokens into the cookie session
# to protect Nerves devices from CSRF token rotation attacks.
# Disable if you prefer to store tokens in the HTML.
# config :phoenix_html, :csrf_tokens_via_cookie_session, true # You might or might not have this line

if System.get_env("PHX_SERVER") do
  config :frontend, FrontendWeb.Endpoint, server: true
end

# ───────── common ─────────
# Only configure Repo from DATABASE_URL if MIX_ENV is not :dev
# OR if DATABASE_URL is explicitly set (allowing overrides even in dev if desired).
# This allows dev.exs to fully manage its DB config without needing DATABASE_URL.

# If you always want dev.exs to control the DB for :dev environment:
if config_env() != :dev do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      It's required for environments other than :dev (e.g., :prod).
      For :dev, ensure your config/dev.exs sets up the Frontend.Repo configuration.
      """

  config :frontend, :cloudfront_domain, System.fetch_env!("CLOUDFRONT_DOMAIN") # Keep if needed universally

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  render_db? = String.contains?(database_url, ".render.com")
  db_host    = URI.parse(database_url).host |> to_charlist()

  ssl_opts =
    if render_db? do
      [
        verify: :verify_peer,
        cacertfile: '/etc/ssl/certs/ca-certificates.crt',
        server_name_indication: db_host
        # hostname: db_host # server_name_indication is usually sufficient
      ]
    else
      # For other DBs via DATABASE_URL, you might need different SSL logic or none
      # Example: allow self-signed certs if DATABASE_URL has ?ssl=true&sslrootcert=...
      # For simplicity here, if not Render DB via URL, assume no special SSL handling needed by default
      # or that the URL itself contains all necessary SSL params.
      if String.contains?(database_url, "ssl=true") or String.contains?(database_url, "sslmode=require") do
        # Basic SSL, could be expanded if certs are needed
        [] # Postgrex will handle basic SSL if the URL indicates it
      else
        false
      end
    end

  repo_url =
    if render_db? and not String.contains?(database_url, "sslmode") and not String.contains?(database_url, "ssl=true") do
      database_url <> "?sslmode=require"
    else
      database_url
    end

  config :frontend, Frontend.Repo,
    url: repo_url,
    ssl: ssl_opts,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

else
  # In :dev environment, we assume config/dev.exs handles Repo config.
  # You can still set CLOUDFRONT_DOMAIN or other shared settings here if needed for dev.
  # If CLOUDFRONT_DOMAIN is also set in dev.exs, that will take precedence.
  # If it's ONLY needed when DATABASE_URL is used, move it inside the `if config_env() != :dev` block.
  # For now, let's assume it might be needed in dev too, fetched from env.
  if cloudfront_domain_env = System.get_env("CLOUDFRONT_DOMAIN") do
    config :frontend, :cloudfront_domain, cloudfront_domain_env
  else
    # Optional: provide a default or raise if it's critical for dev too
    # config :frontend, :cloudfront_domain, "http://localhost:4000" # Example default
    IO.puts("Warning: CLOUDFRONT_DOMAIN not set, some image URLs might be broken in dev.")
  end
end


# ───────── production only ─────────
if config_env() == :prod do
  # SECRET_KEY_BASE is critical for prod, ensure it's set
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing for prod"

  host = System.get_env("PHX_HOST") || "example.com" # Default for safety
  port = String.to_integer(System.get_env("PORT") || "4000")

  # This DNS_CLUSTER_QUERY is typically for clustered deployments.
  # If you have it, it's likely prod-specific.
  if dns_cluster_query_env = System.get_env("DNS_CLUSTER_QUERY") do
    config :frontend, :dns_cluster_query, dns_cluster_query_env
  end

  config :frontend, FrontendWeb.Endpoint,
    url:  [host: host, port: 443, scheme: "https"], # Assuming prod is HTTPS
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
    # Consider adding force_ssl: [hsts: true] for prod here
end
