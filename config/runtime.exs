import Config

if System.get_env("PHX_SERVER") do
  config :heaters, HeatersWeb.Endpoint, server: true
end

runtime_mode = config_env()

app_env =
  case runtime_mode do
    :prod -> "production"
    :test -> "test"
    _ -> "development"
  end

config :heaters, :app_env, app_env

{cloudfront_domain, s3_bucket} =
  case runtime_mode do
    :prod ->
      cloudfront_domain =
        System.get_env("PROD_CLOUDFRONT_DOMAIN") ||
          System.get_env("CLOUDFRONT_DOMAIN") ||
          raise "PROD_CLOUDFRONT_DOMAIN or CLOUDFRONT_DOMAIN is required in production"

      s3_bucket =
        System.get_env("PROD_S3_BUCKET_NAME") ||
          System.get_env("S3_BUCKET_NAME") ||
          raise "PROD_S3_BUCKET_NAME or S3_BUCKET_NAME is required in production"

      {cloudfront_domain, s3_bucket}

    :test ->
      {"test.cloudfront.test", "test-bucket"}

    _ ->
      {
        System.get_env("DEV_CLOUDFRONT_DOMAIN") || System.get_env("CLOUDFRONT_DOMAIN"),
        System.get_env("DEV_S3_BUCKET_NAME") || System.get_env("S3_BUCKET_NAME") || "heaters-dev"
      }
  end

config :heaters, :cloudfront_domain, cloudfront_domain
config :heaters, :s3_bucket, s3_bucket

cloudfront_streaming_enabled = System.get_env("CLOUDFRONT_STREAMING_ENABLED", "true") == "true"
proxy_cdn_domain = System.get_env("PROXY_CDN_DOMAIN") || cloudfront_domain
master_storage_class = System.get_env("MASTER_STORAGE_CLASS", "STANDARD")
proxy_storage_class = System.get_env("PROXY_STORAGE_CLASS", "STANDARD")

config :heaters, :cloudfront_streaming_enabled, cloudfront_streaming_enabled
config :heaters, :proxy_cdn_domain, proxy_cdn_domain
config :heaters, :master_storage_class, master_storage_class
config :heaters, :proxy_storage_class, proxy_storage_class

if runtime_mode == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      System.get_env("PROD_DATABASE_URL") ||
      raise "DATABASE_URL or PROD_DATABASE_URL is required in production"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :heaters, Heaters.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is required in production"

  host =
    System.get_env("PHX_HOST") ||
      raise "PHX_HOST is required in production"

  port = String.to_integer(System.get_env("PORT") || "4000")

  if dns_cluster_query_env = System.get_env("DNS_CLUSTER_QUERY") do
    config :heaters, :dns_cluster_query, dns_cluster_query_env
  end

  config :heaters, HeatersWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    force_ssl: [hsts: true, host: host],
    cache_static_manifest: "priv/static/cache_manifest.json"

  oban_config = Application.get_env(:heaters, Oban, [])
  canonical_queues = Keyword.get(oban_config, :queues, [])
  canonical_plugins = Keyword.get(oban_config, :plugins, [])

  name_to_queue =
    Map.new(canonical_queues, fn {queue_name, concurrency} ->
      {Atom.to_string(queue_name), {queue_name, concurrency}}
    end)

  requested_queue_names =
    System.get_env("OBAN_QUEUES", "default")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()

  unknown_queue_names =
    requested_queue_names
    |> Enum.reject(&Map.has_key?(name_to_queue, &1))

  if unknown_queue_names != [] do
    allowed_queue_names =
      name_to_queue
      |> Map.keys()
      |> Enum.sort()
      |> Enum.join(",")

    unknown_names = Enum.join(unknown_queue_names, ",")

    raise """
    OBAN_QUEUES contains unknown queue names: #{unknown_names}
    Allowed queues: #{allowed_queue_names}
    """
  end

  queues =
    requested_queue_names
    |> Enum.map(fn queue_name ->
      Map.fetch!(name_to_queue, queue_name)
    end)
    |> Map.new()

  scheduler_enabled =
    case System.get_env("OBAN_SCHEDULER") do
      value when value in ["true", "1"] -> true
      value when value in ["false", "0"] -> false
      _ -> "default" in requested_queue_names
    end

  plugins =
    if scheduler_enabled do
      canonical_plugins
    else
      Enum.reject(canonical_plugins, fn
        {Oban.Plugins.Cron, _opts} -> true
        Oban.Plugins.Cron -> true
        _ -> false
      end)
    end

  config :heaters, Oban,
    queues: queues,
    plugins: plugins

  python_exe =
    System.get_env("PYTHON_EXECUTABLE") ||
      "/opt/venv/bin/python"
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

  config :heaters, Heaters.Processing.Support.PythonRunner,
    python_executable: python_exe,
    working_dir: working_dir,
    runner_script: "py/runner.py"
end
