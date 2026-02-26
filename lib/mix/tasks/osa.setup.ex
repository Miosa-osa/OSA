defmodule Mix.Tasks.Osa.Setup do
  @moduledoc """
  Interactive setup wizard for OptimalSystemAgent.

  Creates ~/.osa/ directory structure, prompts for API keys,
  asks which machines to enable, and optionally installs the
  macOS LaunchAgent for auto-start.

  Usage: mix osa.setup
  """
  use Mix.Task

  @shortdoc "Interactive OSA setup wizard"

  @osa_dir Path.expand("~/.osa")

  @impl true
  def run(_args) do
    Mix.shell().info("""

    ╔══════════════════════════════════════════════════╗
    ║       OptimalSystemAgent — Setup Wizard          ║
    ╚══════════════════════════════════════════════════╝
    """)

    # 1. Create directory structure
    create_directories()

    # 2. Provider configuration
    provider = configure_provider()

    # 3. API keys
    api_keys = configure_api_keys(provider)

    # 4. Machine selection
    machines = configure_machines()

    # 5. Write config.json
    write_config(provider, api_keys, machines)

    # 6. Create bootstrap files
    create_bootstrap_files()

    # 7. LaunchAgent (macOS only)
    if :os.type() == {:unix, :darwin} do
      configure_launch_agent()
    end

    Mix.shell().info("""

    Setup complete! Your configuration is at ~/.osa/config.json

    Quick start:
      mix chat          # Interactive terminal REPL
      iex -S mix        # Programmatic usage

    """)
  end

  defp create_directories do
    dirs = [
      @osa_dir,
      Path.join(@osa_dir, "skills"),
      Path.join(@osa_dir, "sessions"),
      Path.join(@osa_dir, "data")
    ]

    Enum.each(dirs, fn dir ->
      File.mkdir_p!(dir)
      Mix.shell().info("  Created #{dir}")
    end)
  end

  defp configure_provider do
    Mix.shell().info("\n--- LLM Provider ---")
    Mix.shell().info("  1. Ollama (local, free — recommended)")
    Mix.shell().info("  2. Anthropic (Claude)")
    Mix.shell().info("  3. OpenAI (GPT)")

    choice = Mix.shell().prompt("Select provider [1]:") |> String.trim()

    case choice do
      "2" -> "anthropic"
      "3" -> "openai"
      _ -> "ollama"
    end
  end

  defp configure_api_keys("ollama"), do: %{}

  defp configure_api_keys("anthropic") do
    key = Mix.shell().prompt("Anthropic API key (sk-...):") |> String.trim()
    if key != "", do: %{"ANTHROPIC_API_KEY" => key}, else: %{}
  end

  defp configure_api_keys("openai") do
    key = Mix.shell().prompt("OpenAI API key (sk-...):") |> String.trim()
    if key != "", do: %{"OPENAI_API_KEY" => key}, else: %{}
  end

  defp configure_api_keys(_), do: %{}

  defp configure_machines do
    Mix.shell().info("\n--- Machines ---")
    Mix.shell().info("Core machine is always active (file ops, shell, web search).")
    Mix.shell().info("")

    %{
      "communication" =>
        prompt_bool("Enable Communication machine? (telegram, discord, slack)"),
      "productivity" => prompt_bool("Enable Productivity machine? (calendar, tasks)"),
      "research" =>
        prompt_bool("Enable Research machine? (deep search, summarize, translate)")
    }
  end

  defp configure_launch_agent do
    if prompt_bool("\nInstall macOS LaunchAgent for auto-start on login?") do
      plist_source = Path.join([File.cwd!(), "support", "com.osa.agent.plist"])
      plist_dest = Path.expand("~/Library/LaunchAgents/com.osa.agent.plist")

      if File.exists?(plist_source) do
        content = File.read!(plist_source)

        content =
          String.replace(
            content,
            "REPLACE_WITH_HOME",
            System.get_env("HOME", "/Users/#{System.get_env("USER")}")
          )

        File.write!(plist_dest, content)
        Mix.shell().info("  Installed LaunchAgent at #{plist_dest}")
        Mix.shell().info("  Enable: launchctl load #{plist_dest}")
        Mix.shell().info("  Disable: launchctl unload #{plist_dest}")
      else
        Mix.shell().info("  LaunchAgent plist not found at #{plist_source}")
      end
    end
  end

  defp write_config(provider, api_keys, machines) do
    config = %{
      "version" => "1.0",
      "machines" => machines,
      "provider" => %{
        "default" => provider,
        "model" => default_model(provider)
      },
      "api_keys" => api_keys,
      "scheduler" => %{
        "heartbeat_interval_minutes" => 15,
        "cron_jobs" => []
      },
      "security" => %{
        "workspace_sandbox" => true,
        "tool_timeout_seconds" => 60,
        "require_confirmation_for" => []
      }
    }

    config_path = Path.join(@osa_dir, "config.json")
    File.write!(config_path, Jason.encode!(config, pretty: true))
    Mix.shell().info("\n  Written config to #{config_path}")
  end

  defp create_bootstrap_files do
    identity_path = Path.join(@osa_dir, "IDENTITY.md")

    unless File.exists?(identity_path) do
      File.write!(identity_path, """
      # Identity

      You are a proactive AI assistant powered by Signal Theory.
      You classify every communication before processing it.
      You take initiative when you detect opportunities to help.
      """)

      Mix.shell().info("  Created #{identity_path}")
    end
  end

  defp default_model("anthropic"), do: "claude-opus-4-6"
  defp default_model("openai"), do: "gpt-4o"
  defp default_model(_), do: "llama3.2:latest"

  defp prompt_bool(question) do
    answer = Mix.shell().prompt("#{question} [y/N]:") |> String.trim() |> String.downcase()
    answer in ["y", "yes"]
  end
end
