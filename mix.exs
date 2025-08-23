defmodule Heaters.MixProject do
  use Mix.Project

  def project do
    [
      app: :heaters,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: [
        heaters: [
          steps: [:assemble],
          include_executables: true
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Heaters.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_ecto, "~> 4.4"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.19.0"},
      {:pgvector, "~> 0.3.0"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:dotenvy, "~> 0.8.0", only: [:dev, :test]},
      {:phoenix_html, "~> 3.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1"},
      {:lazy_html, ">= 0.0.0", only: :test},
      {:igniter, "~> 0.4", only: [:dev, :test], runtime: false},
      {:req, "~> 0.4"},
      {:phoenix_live_dashboard, "~> 0.8.2"},
      {:oban, "~> 2.19"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.20"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.1.1"},
      {:plug_cowboy, "~> 2.5"},
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:hackney, "~> 1.20"},
      {:sweet_xml, "~> 0.7"},
      {:ffmpex, "~> 0.11.0"},
      {:tidewave, "~> 0.4", only: :dev},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.deploy": [
        "cmd npm install --prefix assets",
        "cmd npm run --prefix assets deploy",
        "phx.digest"
      ],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # Development workflow aliases (Docker-aware)
      "dev.setup": ["cmd --cd . docker-compose up -d --wait", "deps.get", "ecto.setup"],
      "dev.reset": ["cmd --cd . docker-compose up -d --wait", "ecto.reset"],
      "dev.server": ["cmd --cd . docker-compose up -d --wait", "phx.server"],

      # Check overall code quality
      check: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test --warnings-as-errors"
      ]
    ]
  end
end
