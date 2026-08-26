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
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [resume: :string, continue: :boolean],
        aliases: [r: :resume, c: :continue]
      )

    # Store resume opts for CLI.start to pick up
    if opts[:resume] do
      Application.put_env(:optimal_system_agent, :resume_session_id, opts[:resume])
    end

    if opts[:continue] do
      # cwd-scoped: prefer the most recent session saved for THIS directory so
      # `--continue` in project A never reopens a session from project B. Fall
      # back to the global most-recent only when this dir has no saved session.
      alias OptimalSystemAgent.Agent.SessionPersistence
      cwd = File.cwd!()

      sid =
        case SessionPersistence.find_latest_for_dir(cwd) do
          %{session_id: sid} ->
            sid

          sid when is_binary(sid) ->
            sid

          _ ->
            case SessionPersistence.list(limit: 1) do
              [%{session_id: sid} | _] -> sid
              _ -> nil
            end
        end

      if sid, do: Application.put_env(:optimal_system_agent, :resume_session_id, sid)
    end

    # Silence all boot logs — the CLI should start clean
    Logger.configure(level: :none)

    Mix.Task.run("app.start")

    # Only show errors during runtime
    Logger.configure(level: :error)

    # Ensure ~/.osa/ directory structure exists
    ensure_osa_directory()

    # Seed workspace templates (idempotent)
    OptimalSystemAgent.Onboarding.seed_workspace()

    # Re-run Ollama auto-detect if provider is Ollama
    if Application.get_env(:optimal_system_agent, :default_provider) == :ollama do
      try do
        OptimalSystemAgent.Providers.Ollama.auto_detect_model()
        OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
      rescue
        _ -> :ok
      end
    end

    # CLI.start handles first-run setup wizard + banner
    OptimalSystemAgent.Channels.CLI.start()
  end

  # ── First-run setup ──────────────────────────────────────────────────

  defp ensure_osa_directory do
    dirs = [
      Path.expand("~/.osa"),
      Path.expand("~/.osa/workspace"),
      Path.expand("~/.osa/agents"),
      Path.expand("~/.osa/skills"),
      Path.expand("~/.osa/sessions"),
      Path.expand("~/.osa/exports"),
      Path.expand("~/.osa/prompts"),
      Path.expand("~/.osa/tool-results"),
      Path.expand("~/.osa/worktrees"),
      Path.expand("~/.osa/agent-memory")
    ]

    Enum.each(dirs, &File.mkdir_p!/1)
  rescue
    _ -> :ok
  end
end
