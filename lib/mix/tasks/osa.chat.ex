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

    # Only show errors during runtime
    Logger.configure(level: :error)

    # Ensure ~/.osa/ directory structure exists
    ensure_osa_directory()

    # First-run detection — show setup wizard if needed
    if OptimalSystemAgent.Onboarding.first_run?() do
      run_first_time_setup()
    end

    # Seed workspace templates (idempotent)
    OptimalSystemAgent.Onboarding.seed_workspace()

    # Re-run Ollama auto-detect if provider is Ollama
    if Application.get_env(:optimal_system_agent, :default_provider) == :ollama do
      OptimalSystemAgent.Providers.Ollama.auto_detect_model()
      OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
    end

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

  defp run_first_time_setup do
    alias OptimalSystemAgent.CLI.Prompt

    IO.write(IO.ANSI.clear() <> IO.ANSI.home())

    IO.puts("""
    #{IO.ANSI.bright()}#{IO.ANSI.cyan()}
     ██████╗ ███████╗ █████╗
    ██╔═══██╗██╔════╝██╔══██╗
    ██║   ██║███████╗███████║
    ██║   ██║╚════██║██╔══██║
    ╚██████╔╝███████║██║  ██║
     ╚═════╝ ╚══════╝╚═╝  ╚═╝#{IO.ANSI.reset()}

    #{IO.ANSI.bright()}Welcome to OSA — the Optimal System Agent#{IO.ANSI.reset()}
    #{IO.ANSI.faint()}Let's get you set up. This takes about 30 seconds.#{IO.ANSI.reset()}
    """)

    # Detect what's already available
    detected = OptimalSystemAgent.Onboarding.detect_existing()
    detected_providers = detected.detected |> Enum.filter(& &1.detected)
    ollama_ok = detected.ollama_local[:reachable]

    # Show what was auto-detected
    if detected_providers != [] or ollama_ok do
      IO.puts("  #{IO.ANSI.green()}Auto-detected:#{IO.ANSI.reset()}")
      if ollama_ok, do: IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Ollama (local)")
      Enum.each(detected_providers, fn p ->
        IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{p.name} (#{p.key_preview})")
      end)
      IO.puts("")
    end

    # Provider selection
    provider =
      cond do
        # If Anthropic key is detected, use it
        Enum.any?(detected_providers, & &1.id == "anthropic") ->
          IO.puts("  #{IO.ANSI.faint()}Using Anthropic (detected API key)#{IO.ANSI.reset()}\n")
          :anthropic

        # If Ollama is running, use it
        ollama_ok ->
          IO.puts("  #{IO.ANSI.faint()}Using Ollama (local, detected)#{IO.ANSI.reset()}\n")
          :ollama

        # If any provider detected, use the first one
        detected_providers != [] ->
          first = hd(detected_providers)
          IO.puts("  #{IO.ANSI.faint()}Using #{first.name} (detected)#{IO.ANSI.reset()}\n")
          String.to_atom(first.id)

        # Nothing detected — ask
        true ->
          IO.puts("  #{IO.ANSI.yellow()}No providers detected.#{IO.ANSI.reset()}")
          IO.puts("  #{IO.ANSI.faint()}You need an LLM provider to use OSA.#{IO.ANSI.reset()}")
          IO.puts("")
          IO.puts("  Options:")
          IO.puts("  #{IO.ANSI.cyan()}1#{IO.ANSI.reset()} Ollama (free, local — install from ollama.com)")
          IO.puts("  #{IO.ANSI.cyan()}2#{IO.ANSI.reset()} Anthropic (paste API key)")
          IO.puts("  #{IO.ANSI.cyan()}3#{IO.ANSI.reset()} OpenAI (paste API key)")
          IO.puts("  #{IO.ANSI.cyan()}4#{IO.ANSI.reset()} Groq (paste API key)")
          IO.puts("")

          choice = IO.gets("  Choose [1-4]: ") |> String.trim()

          case choice do
            "1" -> :ollama
            "2" ->
              key = IO.gets("  Anthropic API key: ") |> String.trim()
              if key != "", do: System.put_env("ANTHROPIC_API_KEY", key)
              :anthropic
            "3" ->
              key = IO.gets("  OpenAI API key: ") |> String.trim()
              if key != "", do: System.put_env("OPENAI_API_KEY", key)
              :openai
            "4" ->
              key = IO.gets("  Groq API key: ") |> String.trim()
              if key != "", do: System.put_env("GROQ_API_KEY", key)
              :groq
            _ -> :ollama
          end
      end

    # Apply the provider
    Application.put_env(:optimal_system_agent, :default_provider, provider)

    # Write .env file
    env_lines = ["OSA_DEFAULT_PROVIDER=#{provider}"]
    env_lines = if System.get_env("ANTHROPIC_API_KEY"), do: env_lines ++ ["ANTHROPIC_API_KEY=#{System.get_env("ANTHROPIC_API_KEY")}"], else: env_lines
    env_lines = if System.get_env("OPENAI_API_KEY"), do: env_lines ++ ["OPENAI_API_KEY=#{System.get_env("OPENAI_API_KEY")}"], else: env_lines
    env_lines = if System.get_env("GROQ_API_KEY"), do: env_lines ++ ["GROQ_API_KEY=#{System.get_env("GROQ_API_KEY")}"], else: env_lines

    env_path = Path.expand("~/.osa/.env")
    File.write!(env_path, Enum.join(env_lines, "\n") <> "\n")

    IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Configuration saved to #{IO.ANSI.faint()}~/.osa/.env#{IO.ANSI.reset()}")
    IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Ready to go!\n")
    IO.puts("  #{IO.ANSI.faint()}Type your message to start. /help for commands. exit to quit.#{IO.ANSI.reset()}\n")

    # Reload config
    OptimalSystemAgent.Application.load_provider_env(provider)
    OptimalSystemAgent.Soul.reload()
  rescue
    e ->
      IO.puts("  #{IO.ANSI.yellow()}Setup error: #{Exception.message(e)}#{IO.ANSI.reset()}")
      IO.puts("  #{IO.ANSI.faint()}Continuing with defaults...#{IO.ANSI.reset()}\n")
  end
end
