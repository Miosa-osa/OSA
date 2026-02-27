defmodule Mix.Tasks.Osa.Chat do
  @moduledoc """
  Start an interactive CLI chat session with the agent.

  Usage: mix osa.chat
  """
  use Mix.Task

  @shortdoc "Start interactive CLI chat"

  @impl true
  def run(_args) do
    # Silence all boot logs — the CLI should start clean
    Logger.configure(level: :none)

    Mix.Task.run("app.start")

    # Restore warnings after boot
    Logger.configure(level: :warning)

    if OptimalSystemAgent.Onboarding.first_run?() do
      OptimalSystemAgent.Onboarding.run()
      OptimalSystemAgent.Soul.reload()
    end

    # Always apply config.json — overrides runtime.exs env var auto-detection
    # so the user's explicit provider choice in config.json is respected.
    OptimalSystemAgent.Onboarding.apply_config()

    # Re-run Ollama auto-detect AFTER apply_config, because config.json may
    # contain the onboarding default "llama3.2:latest" which overwrites
    # the auto-detected best model from Application.start/2.
    if Application.get_env(:optimal_system_agent, :default_provider) == :ollama do
      OptimalSystemAgent.Providers.Ollama.auto_detect_model()
      OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
    end

    OptimalSystemAgent.Channels.CLI.start()
  end
end
