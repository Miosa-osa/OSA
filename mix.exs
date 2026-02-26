defmodule OptimalSystemAgent.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Miosa-osa/OSA"

  def project do
    [
      app: :optimal_system_agent,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "OptimalSystemAgent",
      description: "Signal Theory-optimized proactive AI agent. Run locally. Elixir/OTP.",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {OptimalSystemAgent.Application, []}
    ]
  end

  defp deps do
    [
      # Event routing — compiled Erlang bytecode dispatch (BEAM speed)
      {:goldrush, "~> 0.1.9"},

      # HTTP client for LLM APIs
      {:req, "~> 0.5"},

      # JSON
      {:jason, "~> 1.4"},

      # PubSub for internal event fan-out (standalone, no Phoenix framework)
      {:phoenix_pubsub, "~> 2.1"},

      # Filesystem watching (skill hot reload)
      {:file_system, "~> 1.0"},

      # YAML parsing (skills, config)
      {:yaml_elixir, "~> 2.9"},

      # HTTP server for webhooks + MCP (lightweight, no Phoenix)
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},

      # Database — Ecto + SQLite3
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},

      # Telemetry
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "compile"],
      chat: ["run --no-halt -e 'OptimalSystemAgent.Channels.CLI.start()'"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CONTRIBUTING.md", "LICENSE"]
    ]
  end
end
