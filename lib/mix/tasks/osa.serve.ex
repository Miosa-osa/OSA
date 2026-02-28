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
    Logger.configure(level: :warning)
    Mix.Task.run("app.start")

    if OptimalSystemAgent.Onboarding.first_run?() do
      Logger.info("First run detected — complete setup via TUI or: mix osa.setup")
    end

    OptimalSystemAgent.Onboarding.apply_config()

    if Application.get_env(:optimal_system_agent, :default_provider) == :ollama do
      OptimalSystemAgent.Providers.Ollama.auto_detect_model()
      OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
    end

    port = Application.get_env(:optimal_system_agent, :http_port, 8089)
    IO.puts("OSA backend serving on http://localhost:#{port}")
    IO.puts("Connect with: cd priv/go/tui-v2 && ./osa")
    IO.puts("Or: curl http://localhost:#{port}/health")
    Process.sleep(:infinity)
  end
end
