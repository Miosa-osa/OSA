defmodule OptimalSystemAgent.CLI do
  @moduledoc """
  Entry point for the `osagent` release binary.

  Dispatches subcommands:
    osagent           interactive chat (default)
    osagent setup     configure provider, API keys
    osagent version   print version
    osagent serve     headless HTTP API mode
  """

  @app :optimal_system_agent

  def chat do
    # Silence boot logs for clean CLI startup
    Logger.configure(level: :none)

    {:ok, _} = Application.ensure_all_started(@app)

    Logger.configure(level: :warning)

    migrate!()

    if OptimalSystemAgent.Onboarding.first_run?() do
      OptimalSystemAgent.Onboarding.run()
      OptimalSystemAgent.Soul.reload()
    end

    OptimalSystemAgent.Onboarding.apply_config()
    OptimalSystemAgent.Channels.CLI.start()
  end

  def setup do
    {:ok, _} = Application.ensure_all_started(:jason)
    OptimalSystemAgent.Onboarding.run_setup_mode()
  end

  def version do
    Application.load(@app)
    vsn = Application.spec(@app, :vsn) |> to_string()
    IO.puts("osagent v#{vsn}")
  end

  def serve do
    {:ok, _} = Application.ensure_all_started(@app)
    migrate!()
    OptimalSystemAgent.Onboarding.apply_config()

    port = Application.get_env(@app, :http_port, 8089)
    IO.puts("OSA serving on :#{port}")
    Process.sleep(:infinity)
  end

  # ── Migrations ──────────────────────────────────────────────────

  defp migrate! do
    priv = :code.priv_dir(@app) |> to_string()
    migrations_path = Path.join([priv, "repo", "migrations"])

    if File.dir?(migrations_path) do
      Ecto.Migrator.run(
        OptimalSystemAgent.Store.Repo,
        migrations_path,
        :up,
        all: true,
        log: false
      )
    end
  end
end
