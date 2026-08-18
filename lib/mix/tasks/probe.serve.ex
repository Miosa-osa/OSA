defmodule Mix.Tasks.Probe.Serve do
  use Mix.Task
  require Logger

  @impl true
  def run(_args) do
    Logger.configure(level: :warning)
    Mix.Task.run("app.start")
    IO.puts(">>> PROBE: reached after app.start")

    OptimalSystemAgent.Onboarding.seed_workspace()
    IO.puts(">>> PROBE: reached after seed_workspace")

    if Application.get_env(:optimal_system_agent, :default_provider) == :ollama do
      OptimalSystemAgent.Providers.Ollama.auto_detect_model()
      IO.puts(">>> PROBE: reached after auto_detect_model")
      OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
      IO.puts(">>> PROBE: reached after detect_ollama_tiers")
    end

    IO.puts(">>> PROBE: about to sleep infinity")
    Process.sleep(:infinity)
  end
end
