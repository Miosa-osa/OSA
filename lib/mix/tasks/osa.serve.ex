defmodule Mix.Tasks.Osa.Serve do
  @moduledoc """
  Start the OSA backend HTTP server without the built-in CLI.

  Use this when connecting the Go TUI or other external clients.

  Usage: mix osa.serve
  """
  use Mix.Task
  require Logger

  @shortdoc "Start HTTP backend (no CLI)"

  @impl true
  def run(_args) do
    # Suppress boot noise — the Go TUI owns the terminal.
    # Logger level must be set both before and after app.start because
    # app.start may re-configure Logger from config files.
    Logger.configure(level: :warning)
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    if OptimalSystemAgent.Onboarding.first_run?() do
      OptimalSystemAgent.Onboarding.run()
      OptimalSystemAgent.Soul.reload()
    end

    OptimalSystemAgent.Onboarding.apply_config()

    if Application.get_env(:optimal_system_agent, :default_provider) == :ollama do
      OptimalSystemAgent.Providers.Ollama.auto_detect_model()
      OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
    end

    port = Application.get_env(:optimal_system_agent, :http_port, 8089)
    Logger.info("OSA backend serving on http://localhost:#{port}")
    Process.sleep(:infinity)
  end
end
