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

    # Scan for existing providers
    detected = OptimalSystemAgent.Onboarding.detect_existing()
    detected_providers = detected.detected |> Enum.filter(& &1.detected)
    ollama_ok = detected.ollama_local[:reachable]
    has_detections = detected_providers != [] or ollama_ok

    # Show what was found
    if has_detections do
      IO.puts("  #{IO.ANSI.green()}Detected on your system:#{IO.ANSI.reset()}")
      if ollama_ok, do: IO.puts("    #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Ollama (local)")

      Enum.each(detected_providers, fn p ->
        IO.puts("    #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{p.name} (#{p.key_preview})")
      end)

      IO.puts("")
    end

    # Give the user a choice
    IO.puts("  How would you like to set up?")
    IO.puts("")

    if has_detections do
      IO.puts(
        "  #{IO.ANSI.cyan()}1#{IO.ANSI.reset()} #{IO.ANSI.bright()}Quick Start#{IO.ANSI.reset()} — use detected provider automatically"
      )
    end

    IO.puts(
      "  #{IO.ANSI.cyan()}2#{IO.ANSI.reset()} #{IO.ANSI.bright()}Manual Setup#{IO.ANSI.reset()} — choose your provider and enter API key"
    )

    IO.puts(
      "  #{IO.ANSI.cyan()}3#{IO.ANSI.reset()} #{IO.ANSI.bright()}Skip#{IO.ANSI.reset()} — configure later with #{IO.ANSI.faint()}/model#{IO.ANSI.reset()} or #{IO.ANSI.faint()}~/.osa/.env#{IO.ANSI.reset()}"
    )

    IO.puts("")

    setup_choice =
      IO.gets("  Choose [#{if has_detections, do: "1-3", else: "2-3"}]: ") |> String.trim()

    provider =
      case setup_choice do
        "1" when has_detections ->
          # Quick start — pick best detected provider
          best =
            cond do
              Enum.any?(detected_providers, &(&1.id == "anthropic")) -> :anthropic
              Enum.any?(detected_providers, &(&1.id == "openai")) -> :openai
              ollama_ok -> :ollama
              true -> String.to_atom(hd(detected_providers).id)
            end

          IO.puts("\n  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Using #{best}\n")
          best

        "2" ->
          # Full manual setup
          run_manual_provider_setup()

        "3" ->
          # Skip — use Ollama as default
          IO.puts(
            "\n  #{IO.ANSI.faint()}Skipping setup. Using Ollama as default.#{IO.ANSI.reset()}"
          )

          IO.puts(
            "  #{IO.ANSI.faint()}Configure anytime: /model or edit ~/.osa/.env#{IO.ANSI.reset()}\n"
          )

          :ollama

        _ ->
          if has_detections do
            # Default to quick start if they just hit enter
            best =
              cond do
                Enum.any?(detected_providers, &(&1.id == "anthropic")) -> :anthropic
                ollama_ok -> :ollama
                true -> :ollama
              end

            IO.puts("\n  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Using #{best}\n")
            best
          else
            run_manual_provider_setup()
          end
      end

    # Apply the chosen provider
    Application.put_env(:optimal_system_agent, :default_provider, provider)

    # Write .env file
    env_lines = ["OSA_DEFAULT_PROVIDER=#{provider}"]

    env_lines =
      if System.get_env("ANTHROPIC_API_KEY"),
        do: env_lines ++ ["ANTHROPIC_API_KEY=#{System.get_env("ANTHROPIC_API_KEY")}"],
        else: env_lines

    env_lines =
      if System.get_env("OPENAI_API_KEY"),
        do: env_lines ++ ["OPENAI_API_KEY=#{System.get_env("OPENAI_API_KEY")}"],
        else: env_lines

    env_lines =
      if System.get_env("GROQ_API_KEY"),
        do: env_lines ++ ["GROQ_API_KEY=#{System.get_env("GROQ_API_KEY")}"],
        else: env_lines

    env_path = Path.expand("~/.osa/.env")
    File.write!(env_path, Enum.join(env_lines, "\n") <> "\n")

    IO.puts(
      "  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Configuration saved to #{IO.ANSI.faint()}~/.osa/.env#{IO.ANSI.reset()}"
    )

    IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Ready to go!\n")

    IO.puts(
      "  #{IO.ANSI.faint()}Type your message to start. /help for commands. exit to quit.#{IO.ANSI.reset()}\n"
    )

    # Reload config
    OptimalSystemAgent.Application.load_provider_env(provider)
    OptimalSystemAgent.Soul.reload()

    # Tell CLI.start not to clear the screen (our setup wizard output is still showing)
    Application.put_env(:optimal_system_agent, :skip_banner_clear, true)
  rescue
    e ->
      IO.puts("  #{IO.ANSI.yellow()}Setup error: #{Exception.message(e)}#{IO.ANSI.reset()}")
      IO.puts("  #{IO.ANSI.faint()}Continuing with defaults...#{IO.ANSI.reset()}\n")
  end

  defp run_manual_provider_setup do
    IO.puts("")
    IO.puts("  #{IO.ANSI.bright()}Choose your LLM provider:#{IO.ANSI.reset()}")
    IO.puts("")

    IO.puts(
      "  #{IO.ANSI.cyan()}1#{IO.ANSI.reset()} Ollama       #{IO.ANSI.faint()}Free, runs locally. Install from ollama.com#{IO.ANSI.reset()}"
    )

    IO.puts(
      "  #{IO.ANSI.cyan()}2#{IO.ANSI.reset()} Anthropic    #{IO.ANSI.faint()}Claude models. Get key at console.anthropic.com#{IO.ANSI.reset()}"
    )

    IO.puts(
      "  #{IO.ANSI.cyan()}3#{IO.ANSI.reset()} OpenAI       #{IO.ANSI.faint()}GPT models. Get key at platform.openai.com#{IO.ANSI.reset()}"
    )

    IO.puts(
      "  #{IO.ANSI.cyan()}4#{IO.ANSI.reset()} Groq         #{IO.ANSI.faint()}Fast inference. Get key at console.groq.com#{IO.ANSI.reset()}"
    )

    IO.puts(
      "  #{IO.ANSI.cyan()}5#{IO.ANSI.reset()} OpenRouter   #{IO.ANSI.faint()}Multi-provider gateway. Get key at openrouter.ai#{IO.ANSI.reset()}"
    )

    IO.puts(
      "  #{IO.ANSI.cyan()}6#{IO.ANSI.reset()} Together     #{IO.ANSI.faint()}Open-source models. Get key at together.ai#{IO.ANSI.reset()}"
    )

    IO.puts("")

    choice = IO.gets("  Choose [1-6]: ") |> String.trim()

    {provider, env_var} =
      case choice do
        "1" -> {:ollama, nil}
        "2" -> {:anthropic, "ANTHROPIC_API_KEY"}
        "3" -> {:openai, "OPENAI_API_KEY"}
        "4" -> {:groq, "GROQ_API_KEY"}
        "5" -> {:openrouter, "OPENROUTER_API_KEY"}
        "6" -> {:together, "TOGETHER_API_KEY"}
        _ -> {:ollama, nil}
      end

    case {provider, env_var} do
      {:ollama, nil} ->
        IO.puts(
          "\n  #{IO.ANSI.faint()}Make sure Ollama is running: ollama serve#{IO.ANSI.reset()}"
        )

      {:anthropic, env_var} ->
        # Anthropic used to fork here into "Sign in with your Anthropic
        # account (OAuth)" vs "Paste API key". The sign-in branch was removed
        # (see `OptimalSystemAgent.Auth.LegacyAnthropicOAuth`); Anthropic is
        # API-key only, like every other cloud provider here.
        setup_api_key(:anthropic, env_var)

      {_, env_var} when is_binary(env_var) ->
        # Standard API key flow for other providers
        setup_api_key(provider, env_var)
    end

    IO.puts("")
    IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Provider configured: #{provider}\n")
    provider
  rescue
    _ -> :ollama
  end

  defp setup_api_key(provider, env_var) do
    IO.puts("")
    key = IO.gets("  #{IO.ANSI.bright()}API Key:#{IO.ANSI.reset()} ") |> String.trim()

    if key != "" do
      System.put_env(env_var, key)

      masked =
        if String.length(key) > 8 do
          String.slice(key, 0, 4) <> "..." <> String.slice(key, -4, 4)
        else
          "****"
        end

      IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Key set (#{masked})")
    else
      IO.puts(
        "  #{IO.ANSI.yellow()}No key entered — set it later in ~/.osa/.env#{IO.ANSI.reset()}"
      )
    end

    # Model preference
    IO.puts("")
    IO.puts("  #{IO.ANSI.faint()}Model (press Enter for default):#{IO.ANSI.reset()}")
    model = IO.gets("  Model: ") |> String.trim()

    if model != "" do
      model_env = String.upcase(to_string(provider)) <> "_MODEL"
      System.put_env(model_env, model)
      IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} Model: #{model}")
    end
  end
end
