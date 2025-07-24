import Config

# Configure phoenix_html to move CSRF tokens into the cookie session
# to protect Nerves devices from CSRF token rotation attacks.
# Disable if you prefer to store tokens in the HTML.
# config :phoenix_html, :csrf_tokens_via_cookie_session, true # Keep if you have this line

if System.get_env("PHX_SERVER") do
  config :heaters, HeatersWeb.Endpoint, server: true
end

# === S3/CloudFront Configuration (based on APP_ENV) ===
# Skip external service configuration for test environment
# APP_ENV is expected to be "development" for local Docker Compose runs (from .env)
# and "production" for Render deployments (set in Render service environment).

# Check if we're running a database-only operation (migrations, etc.)
# These operations don't need CloudFront configuration
is_database_operation =
  System.argv()
  |> Enum.any?(fn arg ->
    String.contains?(arg, "ecto.") or
      String.contains?(arg, "migrate") or
      String.contains?(arg, "rollback") or
      String.contains?(arg, "setup") or
      String.contains?(arg, "create") or
      String.contains?(arg, "drop")
  end)

if config_env() != :test and not is_database_operation do
  app_env_string = System.get_env("APP_ENV")

  # Make APP_ENV available in application config if needed
  config :heaters, :app_env, app_env_string

  # Configure Cloudfront Domain
  current_cloudfront_domain =
    case app_env_string do
      "development" ->
        # In local dev (docker-compose with APP_ENV="development"), expect CLOUDFRONT_DEV_DOMAIN from .env.
        System.get_env("CLOUDFRONT_DEV_DOMAIN") ||
          raise "CLOUDFRONT_DEV_DOMAIN not set for APP_ENV=development. Please set it in your .env file."

      "production" ->
        # In production (Render with APP_ENV="production"), expect CLOUDFRONT_PROD_DOMAIN.
        System.get_env("CLOUDFRONT_PROD_DOMAIN") ||
          raise "CLOUDFRONT_PROD_DOMAIN not set for APP_ENV=production. Please set it in your Render environment variables."

      _ ->
        # APP_ENV not "development" or "production" (e.g., nil during compile time or local mix outside Docker).
        # This case should ideally not be hit if APP_ENV is always correctly set.
        # For safety during build or other contexts, try to infer, but log a significant warning.
        effective_mix_env = config_env()

        IO.puts(
          :stderr,
          "Critical Warning: APP_ENV is '#{app_env_string || "not set"}'. Attempting to infer CloudFront domain using MIX_ENV=#{effective_mix_env}, but this is not recommended. Ensure APP_ENV is correctly set to 'development' or 'production'."
        )

        cond do
          effective_mix_env == :prod ->
            System.get_env("CLOUDFRONT_PROD_DOMAIN") ||
              raise "CLOUDFRONT_PROD_DOMAIN not set, and APP_ENV was not 'production' during a :prod mix_env context."

          effective_mix_env == :dev ->
            System.get_env("CLOUDFRONT_DEV_DOMAIN") ||
              raise "CLOUDFRONT_DEV_DOMAIN not set, and APP_ENV was not 'development' during a :dev mix_env context."

          # Default fallback if MIX_ENV is also something unexpected
          true ->
            raise "Cannot determine CloudFront domain: APP_ENV is '#{app_env_string || "not set"}' and MIX_ENV is '#{effective_mix_env}'. Please check your environment configuration."
        end
    end

  config :heaters, :cloudfront_domain, current_cloudfront_domain
  IO.puts("[Runtime.exs] Configured CloudFront Domain: #{current_cloudfront_domain}")

  # Configure S3 Bucket Name (if Phoenix needs to know it directly for URL generation, etc.)
  current_s3_bucket =
    case app_env_string do
      "development" ->
        # Fallback to generic if _DEV_ missing
        System.get_env("S3_DEV_BUCKET_NAME") || System.get_env("S3_BUCKET_NAME")

      "production" ->
        # Fallback to generic if _PROD_ missing
        System.get_env("S3_PROD_BUCKET_NAME") || System.get_env("S3_BUCKET_NAME")

      _ ->
        # Fallback if APP_ENV is not explicitly "development" or "production".
        # Relies on S3_BUCKET_NAME being appropriately set in the environment (e.g. from .env via direnv).
        effective_mix_env = config_env()

        IO.puts(
          :stderr,
          "Warning: APP_ENV is '#{app_env_string || "not set"}'. Inferring S3 Bucket using MIX_ENV=#{effective_mix_env}."
        )

        # For S3 bucket, typically you'd want it to be mandatory if needed.
        # If it's critical for prod builds, System.fetch_env! might be appropriate in the :prod branch here.
        # This will be nil if not set, Phoenix code should handle nil if it's optional.
        System.get_env("S3_BUCKET_NAME")
    end

  if current_s3_bucket do
    config :heaters, :s3_bucket, current_s3_bucket
    IO.puts("[Runtime.exs] Configured S3 Bucket: #{current_s3_bucket}")
  else
    IO.puts("[Runtime.exs] S3 Bucket not configured via APP_ENV specific vars or S3_BUCKET_NAME.")
  end

  # Configure WebCodecs support and proxy settings
  webcodecs_enabled = System.get_env("WEBCODECS_ENABLED", "true") == "true"
  config :heaters, :webcodecs_enabled, webcodecs_enabled

  # Configure CDN domain for proxy video streaming (supports range requests)
  proxy_cdn_domain = System.get_env("PROXY_CDN_DOMAIN") || current_cloudfront_domain
  config :heaters, :proxy_cdn_domain, proxy_cdn_domain

  # Configure storage classes for cost optimization
  master_storage_class = System.get_env("MASTER_STORAGE_CLASS", "GLACIER")
  proxy_storage_class = System.get_env("PROXY_STORAGE_CLASS", "STANDARD")

  config :heaters, :master_storage_class, master_storage_class
  config :heaters, :proxy_storage_class, proxy_storage_class

  IO.puts("[Runtime.exs] WebCodecs enabled: #{webcodecs_enabled}")
  IO.puts("[Runtime.exs] Proxy CDN domain: #{proxy_cdn_domain}")
  IO.puts("[Runtime.exs] Master storage: #{master_storage_class}")
  IO.puts("[Runtime.exs] Proxy storage: #{proxy_storage_class}")
else
  # In test environment or database operations, configure minimal stubs for S3/CloudFront
  if is_database_operation do
    config :heaters, :app_env, System.get_env("APP_ENV") || "development"
    config :heaters, :cloudfront_domain, "database-op.cloudfront.test"
    config :heaters, :s3_bucket, "database-op-bucket"
    IO.puts("[Runtime.exs] Database operation - using minimal CloudFront/S3 configuration.")
  else
    # Test environment
    config :heaters, :app_env, "test"
    config :heaters, :cloudfront_domain, "test.cloudfront.test"
    config :heaters, :s3_bucket, "test-bucket"
    IO.puts("[Runtime.exs] Test environment - using minimal CloudFront/S3 configuration.")
  end
end

# === Database Configuration ===
# Only configure Repo from DATABASE_URL for production environment.
# For :dev and :test, their respective config files manage database configuration.
if config_env() == :prod do
  # For production environment:
  # 1. Try PROD_DATABASE_URL (from .env, for local scripts targeting prod or specific prod-like envs).
  # 2. Fallback to DATABASE_URL (this is what Render injects for its managed DB).
  database_url =
    System.get_env("PROD_DATABASE_URL") ||
      System.get_env("DATABASE_URL") ||
      raise """
      environment variable PROD_DATABASE_URL or DATABASE_URL is missing.
      It's required for production environment.
      For :dev and :test, their respective config files handle database configuration.
      """

  IO.puts(
    "[Runtime.exs] Configuring Repo for #{config_env()} using DATABASE_URL (source: PROD_DATABASE_URL or DATABASE_URL)"
  )

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Check if the database_url points to a Render managed database.
  # System.get_env("RENDER_INSTANCE_ID") is a reliable way to check if running on Render.
  is_on_render_platform = System.get_env("RENDER_INSTANCE_ID") != nil
  is_render_db_host = String.contains?(database_url, ".render.com")

  ssl_opts =
    cond do
      is_on_render_platform and is_render_db_host ->
        # Running on Render platform and connecting to a Render DB.
        # Use CAStore for Render's managed certificates.
        # Add {:castore, "~> 1.0"} to mix.exs deps and CAStore.init() in application.ex if using.
        [
          verify: :verify_peer,
          # Requires CAStore dependency and initialization.
          cacertfile: CAStore.file_path(),
          server_name_indication: URI.parse(database_url).host |> to_charlist()
          # For older Elixir/Erlang, you might need:
          # sni: URI.parse(database_url).host |> String.to_charlist()
        ]

      is_render_db_host ->
        # Connecting to a Render DB host, but NOT from the Render platform (e.g., local script).
        # PROD_DATABASE_URL from .env should include "?sslmode=require".
        # psycopg2/Postgrex handles `sslmode=require` from the DSN.
        # Explicit options can be added if `sslmode=verify-full` is used and CA certs need local management.
        # For `sslmode=require`, often empty list or `ssl: true` is enough if system trusts CAs.
        # Relying on sslmode in URL. For verify-full, you'd need cacertfile path.
        if String.contains?(database_url, "sslmode=verify-full") do
          [
            verify: :verify_peer,
            # cacertfile: "/path/to/your/local/render-ca-cert.pem", # If needed for verify-full
            server_name_indication: URI.parse(database_url).host |> to_charlist()
          ]
        else
          # For sslmode=require, Postgrex handles it if present in URL.
          # If not in URL, `ssl: true` can enable basic SSL.
          if String.contains?(database_url, "sslmode=") or
               String.contains?(database_url, "ssl=true"),
             do: [],
             else: [ssl: true]
        end

      String.contains?(database_url, "ssl=true") or
          String.contains?(database_url, "sslmode=require") ->
        # For other non-Render DBs that specify SSL in the URL.
        # Postgrex handles basic SSL if the URL indicates it.
        []

      true ->
        # No SSL indicated or needed.
        false
    end

  # Ensure sslmode=require is part of the URL for Render DBs if not already,
  # to simplify SSL setup, especially if CAStore is not used or for local connections to Render.
  # Your PROD_DATABASE_URL in .env already includes this.
  # This primarily helps if Render's auto-injected DATABASE_URL doesn't include it.
  repo_url_with_sslmode =
    if is_render_db_host and not String.contains?(database_url, "sslmode=") and
         not String.contains?(database_url, "ssl=") do
      database_url <> "?sslmode=require"
    else
      database_url
    end

  config :heaters, Heaters.Repo,
    url: repo_url_with_sslmode,
    ssl: ssl_opts,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6
else
  # In :dev and :test environments, their respective config files handle Repo config.
  IO.puts(
    "[Runtime.exs] Repo configuration for #{config_env()} is handled by config/#{config_env()}.exs."
  )
end

# === Production Only settings (when MIX_ENV=prod) ===
# This block applies settings specifically for production builds/releases.
if config_env() == :prod do
  IO.puts("[Runtime.exs] Applying production-specific endpoint configurations (MIX_ENV=prod).")
  # SECRET_KEY_BASE is critical for prod, ensure it's set.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing for prod"

  # PHX_HOST for constructing canonical URLs.
  # RENDER_EXTERNAL_HOSTNAME is provided by Render.
  host =
    System.get_env("PHX_HOST") || System.get_env("RENDER_EXTERNAL_HOSTNAME") ||
      raise "PHX_HOST or RENDER_EXTERNAL_HOSTNAME must be set for prod"

  port = String.to_integer(System.get_env("PORT") || "4000")

  # DNS_CLUSTER_QUERY is for clustered deployments (e.g., libcluster with DNS strategy).
  if dns_cluster_query_env = System.get_env("DNS_CLUSTER_QUERY") do
    config :heaters, :dns_cluster_query, dns_cluster_query_env
  end

  config :heaters, HeatersWeb.Endpoint,
    # Prod typically runs on HTTPS.
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Listen on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      # Port the app binds to internally on Render.
      port: port
    ],
    secret_key_base: secret_key_base,
    # Enable HSTS and other security headers for production.
    # Ensure host matches for HSTS
    force_ssl: [hsts: true, host: host],
    # For long-lived caching of static assets.
    cache_static_manifest: "priv/static/cache_manifest.json"

  # The `force_ssl` option above implies HTTPS, so `https` scheme is appropriate.
  # Render handles SSL termination at its load balancers, forwarding traffic as HTTP to your app on `port`.
  # Phoenix needs to know the original scheme (https) and host for correct URL generation.

  # --- Oban Dynamic Configuration ---
  # Default to running only the 'default' queue if OBAN_QUEUES is not set.
  # This makes our Render web service safe by default.
  queues_str = System.get_env("OBAN_QUEUES", "default")

  queues =
    queues_str
    |> String.split(",", trim: true)
    |> Enum.map(fn queue_name -> {String.to_atom(queue_name), 10} end)
    |> Map.new()

  # Only the node running the 'default' queue (the web service) will schedule jobs.
  plugins =
    if "default" in String.split(queues_str, ",", trim: true) do
      [
        Oban.Plugins.Pruner,
        {Oban.Plugins.Cron,
         crontab: [{"* * * * *", Heaters.Infrastructure.Orchestration.Dispatcher}]}
      ]
    else
      [Oban.Plugins.Pruner]
    end

  config :heaters, Oban,
    queues: queues,
    plugins: plugins

  # Configure PyRunner for production with strict validation
  python_exe =
    System.get_env("PYTHON_EXECUTABLE") ||
      "/opt/venv/bin/python3"
      |> tap(fn path ->
        unless File.exists?(path) do
          raise "PYTHON_EXECUTABLE does not exist: #{path}"
        end
      end)

  working_dir =
    System.get_env("PYTHON_WORKING_DIR") ||
      "/app"
      |> tap(fn path ->
        unless File.dir?(path) do
          raise "PYTHON_WORKING_DIR does not exist: #{path}"
        end
      end)

  config :heaters, Heaters.Infrastructure.PyRunner,
    python_executable: python_exe,
    working_dir: working_dir,
    runner_script: "py/runner.py"
end

# General debug log at the end of runtime.exs
IO.puts(
  "[Runtime.exs] Runtime configuration finished for MIX_ENV=#{config_env()} and APP_ENV=#{System.get_env("APP_ENV") || "not set"}."
)
