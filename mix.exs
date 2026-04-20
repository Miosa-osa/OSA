defmodule OptimalSystemAgent.MixProject do
  use Mix.Project

  @version "VERSION" |> File.read!() |> String.trim()
  @source_url "https://github.com/Miosa-osa/OSA"

  def project do
    [
      app: :optimal_system_agent,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      name: "OptimalSystemAgent",
      description: "Signal Theory-optimized proactive AI agent. Run locally. Elixir/OTP.",
      source_url: @source_url,
      docs: docs(),
      rustler_crates: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :os_mon, :public_key],
      mod: {OptimalSystemAgent.Application, []}
    ]
  end

  defp deps do
    [
      # Single-binary packaging — wraps a BEAM release into self-contained executables
      {:burrito, "~> 1.0"},

      # Event routing — compiled Erlang bytecode dispatch (BEAM speed)
      # https://github.com/robertohluna/goldrush (fork of extend/goldrush)
      {:goldrush, github: "robertohluna/goldrush", branch: "main", override: true},

      # HTTP client for LLM APIs
      {:req, "~> 0.5"},

      # Low-level HTTP + WebSocket client — OpenComputers extension speaks
      # an outbound-only WSS control channel to MIOSA's control plane.
      {:mint, "~> 1.5"},
      {:mint_web_socket, "~> 1.0"},
      {:castore, "~> 1.0"},

      # JSON
      {:jason, "~> 1.4"},

      # JSON Schema validation (tool argument validation)
      {:ex_json_schema, "~> 0.11"},

      # PubSub for internal event fan-out (standalone, no Phoenix framework)
      {:phoenix_pubsub, "~> 2.1"},

      # YAML parsing (skills, config)
      {:yaml_elixir, "~> 2.9"},

      # HTTP server for webhooks + MCP (lightweight, no Phoenix)
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},

      # Database — Ecto + SQLite3
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},

      # Platform database — PostgreSQL for multi-tenant data
      {:postgrex, "~> 0.19"},

      # Password hashing (only needed for platform multi-tenant auth in prod)
      {:bcrypt_elixir, "~> 3.0", only: :prod, optional: true},

      # AMQP — RabbitMQ publisher for Go worker events (optional)
      {:amqp, "~> 4.1", optional: true},

      # Email — SMTP client for outbound email channel
      {:gen_smtp, "~> 1.2"},

      # Telemetry
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},

      # OTP 28: rustler removed — nif.ex uses pure Elixir fallbacks
      # {:rustler, "~> 0.37", optional: true}

      # PTY spawning — used by OpenComputers.Executor.Direct.Pty to open
      # real interactive shells with full terminal geometry (cols, rows, resize).
      {:erlexec, "~> 2.0"},

      # miosa_* packages are not standalone deps — their implementations live
      # in this repo. Shim modules in lib/miosa/ satisfy all call sites.
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "compile"],
      serve: ["run --no-halt"],
      tui: ["cmd ./scripts/osa-tui.sh"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end

  defp releases do
    [
      # Traditional OTP release — used by Homebrew and local dev builds.
      osagent: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, &copy_go_tokenizer/1, &copy_osagent_wrapper/1],
        rel_templates_path: "rel"
      ],

      # Burrito single-binary release — `mix release burrito` emits one
      # self-contained executable per target into burrito_out/.
      # Build via CI (see .github/workflows/release.yml); cross-compile on
      # your local machine is not supported.
      burrito: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            linux_amd64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            windows_amd64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Copy the pre-built Go tokenizer binary into the release's priv directory.
  # The binary must be compiled before `mix release` (CI does this in a prior step).
  defp copy_go_tokenizer(release) do
    src = Path.join(["priv", "go", "tokenizer", "osa-tokenizer"])

    dst_dir =
      Path.join([
        release.path,
        "lib",
        "optimal_system_agent-#{@version}",
        "priv",
        "go",
        "tokenizer"
      ])

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
    #   osagent                        interactive chat (default)
    #   osagent setup                  configure provider + API keys
    #   osagent version                print version
    #   osagent serve                  headless HTTP API mode
    #   osagent opencomputers <verb>   manage OpenComputers extension

    set -e

    # Resolve symlinks (Homebrew symlinks bin/osagent → libexec/bin/osagent)
    SCRIPT="$0"
    while [ -L "$SCRIPT" ]; do
      DIR=$(cd "$(dirname "$SCRIPT")" && pwd)
      SCRIPT=$(readlink "$SCRIPT")
      case "$SCRIPT" in /*) ;; *) SCRIPT="$DIR/$SCRIPT" ;; esac
    done
    SELF=$(cd "$(dirname "$SCRIPT")" && pwd)
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
      doctor)
        exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.doctor()"
        ;;
      opencomputers)
        shift
        # Pass remaining args as an Elixir list of strings
        ARGS=$(printf '"%s",' "$@")
        ARGS="[${ARGS%,}]"
        exec "$RELEASE_BIN" eval "OptimalSystemAgent.CLI.opencomputers(${ARGS})"
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
