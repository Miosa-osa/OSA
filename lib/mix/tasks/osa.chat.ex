defmodule Mix.Tasks.Osa.Chat do
  @moduledoc """
  Start an interactive CLI chat session with the agent.

  Usage:
    mix osa.chat                  Start a new session
    mix osa.chat --resume ID      Resume a saved session
    mix osa.chat --continue       Resume the most recent session
  """
  use Mix.Task

  @shortdoc "Start interactive CLI chat"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [resume: :string, continue: :boolean],
      aliases: [r: :resume, c: :continue]
    )

    # Store resume opts for CLI.start to pick up
    if opts[:resume] do
      Application.put_env(:optimal_system_agent, :resume_session_id, opts[:resume])
    end

    if opts[:continue] do
      # Find most recent saved session
      case OptimalSystemAgent.Agent.SessionPersistence.list(limit: 1) do
        [%{session_id: sid} | _] ->
          Application.put_env(:optimal_system_agent, :resume_session_id, sid)
        _ -> :ok
      end
    end
    # Silence all boot logs — the CLI should start clean
    Logger.configure(level: :none)

    Mix.Task.run("app.start")

    # Only show errors during runtime — no debug/info/warnings cluttering the CLI
    Logger.configure(level: :error)

    # Seed workspace templates on first run
    OptimalSystemAgent.Onboarding.seed_workspace()

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
