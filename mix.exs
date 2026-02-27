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
      releases: releases(),
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
      # https://github.com/robertohluna/goldrush (fork of extend/goldrush)
      {:goldrush, github: "robertohluna/goldrush", branch: "main", override: true},

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

  defp releases do
    [
      osagent: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, &copy_go_tokenizer/1, &copy_osagent_wrapper/1],
        rel_templates_path: "rel"
      ]
    ]
  end

  # Copy the pre-built Go tokenizer binary into the release's priv directory.
  # The binary must be compiled before `mix release` (CI does this in a prior step).
  defp copy_go_tokenizer(release) do
    src = Path.join(["priv", "go", "tokenizer", "osa-tokenizer"])
    dst_dir = Path.join([release.path, "lib", "optimal_system_agent-#{@version}", "priv", "go", "tokenizer"])

    if File.exists?(src) do
      File.mkdir_p!(dst_dir)
      File.cp!(src, Path.join(dst_dir, "osa-tokenizer"))
    end

    release
  end

  # Install the `osagent` CLI wrapper alongside the release binary.
  # Renames the generated release script (bin/osagent → bin/osagent_release)
  # and copies in our wrapper that dispatches subcommands via `eval`.
  defp copy_osagent_wrapper(release) do
    bin_dir = Path.join(release.path, "bin")
    release_bin = Path.join(bin_dir, "osagent")
    renamed_bin = Path.join(bin_dir, "osagent_release")

    # Rename the release's own boot script
    if File.exists?(release_bin) do
      File.rename!(release_bin, renamed_bin)
    end

    # Write our wrapper
    wrapper = Path.join(bin_dir, "osagent")
    File.write!(wrapper, osagent_wrapper_script())
    File.chmod!(wrapper, 0o755)

    release
  end

  defp osagent_wrapper_script do
    ~S"""
    #!/bin/sh
    # osagent — CLI wrapper for the OTP release.
    #
    # Usage:
    #   osagent              interactive chat (default)
    #   osagent setup        configure provider + API keys
    #   osagent version      print version
    #   osagent serve        headless HTTP API mode

    set -e

    SELF=$(cd "$(dirname "$0")" && pwd)
    RELEASE_BIN="$SELF/osagent_release"

    case "${1:-chat}" in
      version)
        exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.version()"
        ;;
      setup)
        exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.setup()"
        ;;
      serve)
        exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.serve()"
        ;;
      chat|*)
        exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.chat()"
        ;;
    esac
    """
    |> String.trim_leading()
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CONTRIBUTING.md", "LICENSE"]
    ]
  end
end
