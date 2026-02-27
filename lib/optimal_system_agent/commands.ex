defmodule OptimalSystemAgent.Commands do
  @moduledoc """
  Slash command registry — built-in and dynamically created commands.

  Commands are prefixed with `/` in the CLI and can be:
  1. Built-in (hardcoded in this module)
  2. User-created (stored in ETS, persisted to ~/.osa/commands/)
  3. Agent-created (the agent can create commands for the user at runtime)

  ## Usage

      /help                — list available commands
      /status              — system status
      /skills              — list available skills
      /memory              — show memory stats
      /soul                — show current personality config
      /model               — show active LLM provider/model
      /reload              — reload soul/skill files from disk
      /create-command      — create a new custom command
      /new                 — start a fresh session
      /sessions            — list stored sessions
      /resume <id>         — resume a previous session
      /compact             — context compaction stats
      /usage               — token usage breakdown
      /cortex              — cortex bulletin & active topics
      /doctor              — system diagnostics
      /verbose             — toggle verbose output
      /think <level>       — set reasoning depth (fast/normal/deep)
      /config              — show runtime configuration

  ## Custom Commands

  Custom commands are stored as markdown files in `~/.osa/commands/`.
  Each file defines a command that expands into a prompt template:

      ~/.osa/commands/standup.md →
        ---
        name: standup
        description: Generate a daily standup summary
        ---
        Review my recent activity and generate a standup update.
        Include: what I did, what I'm doing, any blockers.

  When a user types `/standup`, the command's instructions become the
  message sent to the agent loop — as if the user typed them.
  """

  use GenServer
  require Logger

  defp commands_dir,
    do: Application.get_env(:optimal_system_agent, :commands_dir, "~/.osa/commands")

  @ets_table :osa_commands
  @settings_table :osa_settings

  defstruct commands: %{}

  # ── Client API ───────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Execute a slash command.

  Returns:
    - `{:command, output}` — display output directly
    - `{:prompt, expanded_text}` — send expanded text to agent loop
    - `{:action, action, output}` — CLI takes action + displays output
    - `:unknown` — command not found
  """
  @spec execute(String.t(), String.t()) ::
          {:command, String.t()}
          | {:prompt, String.t()}
          | {:action, atom() | tuple(), String.t()}
          | :unknown
  def execute(input, session_id) do
    [cmd | args] = String.split(input, ~r/\s+/, parts: 2)
    cmd = String.downcase(cmd)
    arg = List.first(args) || ""

    # Store command name so handlers can identify which command was invoked
    Process.put(:osa_current_cmd, cmd)

    case lookup(cmd) do
      {:builtin, handler} ->
        handler.(arg, session_id)

      {:custom, template} ->
        expanded =
          if arg != "" do
            template <> "\n\nAdditional context: " <> arg
          else
            template
          end

        {:prompt, expanded}

      :not_found ->
        :unknown
    end
  end

  @doc "List all available commands with descriptions."
  @spec list_commands() :: list({String.t(), String.t()})
  def list_commands do
    builtins = Enum.map(builtin_commands(), fn {name, desc, _} -> {name, desc} end)

    customs =
      try do
        :ets.tab2list(@ets_table)
        |> Enum.map(fn {name, _template, desc} -> {name, desc} end)
      rescue
        ArgumentError -> []
      end

    builtins ++ customs
  end

  @doc "Register a custom command at runtime."
  @spec register(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def register(name, description, template) do
    GenServer.call(__MODULE__, {:register, name, description, template})
  end

  # ── GenServer ───────────────────────────────────────────────────

  @doc "Read a per-session setting from ETS. Returns default if unset."
  @spec get_setting(String.t(), atom(), term()) :: term()
  def get_setting(session_id, key, default \\ nil) do
    case :ets.lookup(@settings_table, {session_id, key}) do
      [{_, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  @doc "Write a per-session setting to ETS."
  @spec put_setting(String.t(), atom(), term()) :: :ok
  def put_setting(session_id, key, value) do
    :ets.insert(@settings_table, {{session_id, key}, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── GenServer ───────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    # Create ETS table for command lookup
    :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])

    # Create ETS table for per-session runtime settings
    :ets.new(@settings_table, [:set, :public, :named_table, read_concurrency: true])

    # Load custom commands from disk
    load_custom_commands()

    Logger.info("[Commands] Loaded #{:ets.info(@ets_table, :size)} custom command(s)")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register, name, description, template}, _from, state) do
    name = String.downcase(String.trim(name))

    # Don't allow overriding builtins
    if Enum.any?(builtin_commands(), fn {n, _, _} -> n == name end) do
      {:reply, {:error, "Cannot override built-in command: /#{name}"}, state}
    else
      # Store in ETS
      :ets.insert(@ets_table, {name, template, description})

      # Persist to disk
      persist_command(name, description, template)

      Logger.info("[Commands] Registered custom command: /#{name}")
      {:reply, :ok, state}
    end
  end

  # ── Lookup ──────────────────────────────────────────────────────

  defp lookup(cmd) do
    # Check builtins first
    case Enum.find(builtin_commands(), fn {name, _, _} -> name == cmd end) do
      {_, _, handler} ->
        {:builtin, handler}

      nil ->
        # Check ETS for custom commands
        case :ets.lookup(@ets_table, cmd) do
          [{^cmd, template, _desc}] -> {:custom, template}
          [] -> :not_found
        end
    end
  end

  # ── Built-in Commands ──────────────────────────────────────────

  defp builtin_commands do
    [
      # ── Info ──
      {"help", "Show available commands", &cmd_help/2},
      {"status", "System status", &cmd_status/2},
      {"skills", "List available skills", &cmd_skills/2},
      {"memory", "Memory statistics", &cmd_memory/2},
      {"soul", "Show personality config", &cmd_soul/2},
      {"model", "Show/switch LLM provider", &cmd_model/2},
      {"models", "List installed Ollama models", &cmd_models_shortcut/2},
      {"provider", "Alias for /model", &cmd_model/2},
      {"commands", "List all commands", &cmd_help/2},

      # ── Session Management ──
      {"new", "Start a fresh session", &cmd_new/2},
      {"sessions", "List stored sessions", &cmd_sessions/2},
      {"resume", "Resume a previous session", &cmd_resume/2},
      {"history", "Browse conversation history", &cmd_history/2},

      # ── Channels ──
      {"channels", "Manage channel adapters", &cmd_channels/2},
      {"whatsapp", "WhatsApp Web shortcut", &cmd_whatsapp/2},

      # ── Context & Performance ──
      {"compact", "Context compaction stats", &cmd_compact/2},
      {"usage", "Token usage breakdown", &cmd_usage/2},

      # ── Intelligence ──
      {"cortex", "Cortex bulletin & topics", &cmd_cortex/2},

      # ── Configuration ──
      {"verbose", "Toggle verbose output", &cmd_verbose/2},
      {"think", "Set reasoning depth", &cmd_think/2},
      {"plan", "Toggle autonomous plan mode", &cmd_plan/2},
      {"config", "Show runtime configuration", &cmd_config/2},

      # ── Agents ──
      {"agents", "List all agents in the roster", &cmd_agents/2},
      {"tiers", "Show model tier configuration", &cmd_tiers/2},
      {"swarms", "List swarm presets", &cmd_swarms/2},
      {"hooks", "Show hook pipeline status", &cmd_hooks/2},
      {"learning", "Learning engine metrics", &cmd_learning/2},

      # ── System ──
      {"reload", "Reload soul/skill files", &cmd_reload/2},
      {"doctor", "System diagnostics", &cmd_doctor/2},
      {"setup", "Run channel setup wizard", &cmd_setup/2},
      {"create-command", "Create a new command", &cmd_create/2},

      # ── Workflow ──
      {"commit", "Generate a proper git commit", &cmd_workflow/2},
      {"build", "Build project with auto-detection", &cmd_workflow/2},
      {"test", "Run tests with auto-detection", &cmd_workflow/2},
      {"lint", "Run linting with auto-fix", &cmd_workflow/2},
      {"verify", "Run completion checklist", &cmd_workflow/2},
      {"create-pr", "Create a pull request", &cmd_workflow/2},
      {"fix", "Apply fixes from review", &cmd_workflow/2},
      {"explain", "Explain code or concepts", &cmd_workflow/2},

      # ── Context Priming ──
      {"prime", "Show loaded context", &cmd_prime/2},
      {"prime-backend", "Load Go backend context", &cmd_prime/2},
      {"prime-webdev", "Load React/Next.js context", &cmd_prime/2},
      {"prime-svelte", "Load Svelte/SvelteKit context", &cmd_prime/2},
      {"prime-security", "Load security audit context", &cmd_prime/2},
      {"prime-devops", "Load DevOps/infra context", &cmd_prime/2},
      {"prime-testing", "Load testing/QA context", &cmd_prime/2},
      {"prime-osa", "Load OSA terminal context", &cmd_prime/2},
      {"prime-miosa", "Load MIOSA platform context", &cmd_prime/2},

      # ── Security ──
      {"security-scan", "Run security scan", &cmd_security/2},
      {"secret-scan", "Detect hardcoded secrets", &cmd_security/2},
      {"harden", "Security hardening recommendations", &cmd_security/2},

      # ── Memory ──
      {"mem-search", "Search episodic memory", &cmd_memory_cmd/2},
      {"mem-save", "Save to persistent memory", &cmd_memory_cmd/2},
      {"mem-recall", "Recall memory by topic", &cmd_memory_cmd/2},
      {"mem-list", "List memory entries", &cmd_memory_cmd/2},
      {"mem-stats", "Memory statistics", &cmd_memory_cmd/2},
      {"mem-delete", "Delete memory entry", &cmd_memory_cmd/2},
      {"mem-context", "Save conversation context", &cmd_memory_cmd/2},
      {"mem-export", "Export memory to file", &cmd_memory_cmd/2},

      # ── Scheduler ──
      {"schedule", "Scheduler overview", &cmd_schedule/2},
      {"cron", "Manage cron jobs", &cmd_cron/2},
      {"triggers", "Manage event triggers", &cmd_triggers/2},
      {"heartbeat", "Heartbeat tasks", &cmd_heartbeat/2},

      # ── Task Tracker ──
      {"tasks", "Show/manage tracked tasks", &cmd_tasks/2},

      # ── Analytics ──
      {"analytics", "Usage analytics and metrics", &cmd_utility/2},
      {"debug", "Start systematic debugging", &cmd_utility/2},
      {"search", "Search codebase and docs", &cmd_utility/2},
      {"review", "Code review on recent changes", &cmd_utility/2},
      {"pr-review", "Review a pull request", &cmd_utility/2},
      {"refactor", "Safe code refactoring", &cmd_utility/2},
      {"banner", "Show OSA banner", &cmd_utility/2},
      {"init", "Initialize project", &cmd_utility/2},

      # ── Exit ──
      {"exit", "Exit the CLI", &cmd_exit/2},
      {"quit", "Exit the CLI", &cmd_exit/2},
      {"clear", "Clear the screen", &cmd_clear/2}
    ]
  end

  # ── Info Commands ──────────────────────────────────────────────

  defp cmd_help(_arg, _session_id) do
    custom_cmds =
      try do
        :ets.tab2list(@ets_table)
        |> Enum.map(fn {name, _template, desc} -> {name, desc} end)
      rescue
        ArgumentError -> []
      end

    custom_section =
      if custom_cmds != [] do
        lines =
          Enum.map_join(custom_cmds, "\n", fn {n, d} ->
            "  /#{String.pad_trailing(n, 18)} #{d}"
          end)

        "\nCustom:\n#{lines}\n"
      else
        ""
      end

    output =
      """
      Info:
        /status             System status
        /skills             List available skills
        /memory             Memory statistics
        /soul               Show personality config
        /doctor             System diagnostics

      Model & Provider:
        /model              Show active provider + model
        /model list         List all providers with status
        /model <provider>   Switch provider (e.g. /model anthropic)
        /model <p> <model>  Switch provider + model
        /models             List installed Ollama models
        /model ollama-url   Set Ollama URL (cloud support)

      Session:
        /new                Start a fresh session
        /sessions           List stored sessions
        /resume <id>        Resume a previous session
        /history            Browse conversation history
        /history <id>       View messages in a session
        /history search <q> Search all messages

      Channels:
        /channels                  List all channel adapters
        /channels connect <name>   Start a channel adapter
        /channels disconnect <n>   Stop a channel adapter
        /channels status <name>    Detailed channel status
        /channels test <name>      Verify channel responding
        /whatsapp                  WhatsApp Web status
        /whatsapp connect          Connect via QR code
        /whatsapp disconnect       Logout + stop
        /whatsapp test             Verify connection

      Context:
        /compact            Context compaction stats
        /usage              Token usage breakdown
        /cortex             Cortex bulletin & topics

      Configuration:
        /verbose            Toggle verbose output (signal indicators)
        /think <level>      Set reasoning depth (fast/normal/deep)
        /plan               Toggle autonomous plan mode
        /config             Show runtime configuration
        /setup              Run channel setup wizard
        /reload             Reload soul + prompt files from disk

      Agents:
        /agents             List all agents in the roster
        /agents <name>      Show agent details
        /tiers              Show model tier configuration
        /swarms             List swarm presets
        /hooks              Hook pipeline status
        /learning           Learning engine metrics

      Scheduler:
        /schedule           Scheduler overview (crons, triggers, heartbeat)
        /cron               List cron jobs
        /cron add           Create a new cron job
        /cron run <id>      Execute a cron job immediately
        /cron enable <id>   Enable a cron job
        /cron disable <id>  Disable a cron job
        /cron remove <id>   Remove a cron job
        /triggers           List event triggers
        /triggers add       Create a new trigger
        /triggers remove <id>  Remove a trigger
        /heartbeat          Show heartbeat tasks + next run
        /heartbeat add <t>  Add a heartbeat task

      Commands:
        /create-command     Create a custom slash command
      #{custom_section}
      Examples:
        /agents backend-go              Show the Go backend agent details
        /models                         List Ollama models on your machine
        /model ollama qwen3:32b         Switch to a specific local model
        /model anthropic                Switch to Anthropic Claude
        /create-command standup | Daily standup | Summarize my recent activity
      """
      |> String.trim_trailing()

    {:command, output}
  end

  defp cmd_status(_arg, _session_id) do
    providers = OptimalSystemAgent.Providers.Registry.list_providers()
    skills = OptimalSystemAgent.Skills.Registry.list_tools_direct()
    memory_stats = OptimalSystemAgent.Agent.Memory.memory_stats()
    soul_loaded = if OptimalSystemAgent.Soul.identity(), do: "yes", else: "defaults"

    output =
      """
      System Status:
        providers:  #{length(providers)} loaded
        skills:     #{length(skills)} available
        sessions:   #{memory_stats[:session_count] || 0} stored
        memory:     #{memory_stats[:long_term_size] || 0} bytes
        soul:       #{soul_loaded}
        http:       port #{Application.get_env(:optimal_system_agent, :http_port, 8089)}
      """
      |> String.trim()

    {:command, output}
  end

  defp cmd_skills(_arg, _session_id) do
    skills = OptimalSystemAgent.Skills.Registry.list_tools_direct()

    output =
      if skills == [] do
        "No skills loaded."
      else
        header = "Available skills (#{length(skills)}):\n"

        body =
          Enum.map_join(skills, "\n", fn skill ->
            "  #{String.pad_trailing(skill.name, 18)} #{String.slice(skill.description, 0, 60)}"
          end)

        header <> body
      end

    {:command, output}
  end

  defp cmd_memory(_arg, _session_id) do
    stats = OptimalSystemAgent.Agent.Memory.memory_stats()

    output =
      """
      Memory:
        sessions:    #{stats[:session_count] || 0}
        long-term:   #{stats[:long_term_size] || 0} bytes
        categories:  #{format_categories(stats[:categories])}
        index keys:  #{stats[:index_keywords] || 0}
      """
      |> String.trim()

    {:command, output}
  end

  defp cmd_soul(_arg, _session_id) do
    identity = OptimalSystemAgent.Soul.identity()
    soul = OptimalSystemAgent.Soul.soul()
    user = OptimalSystemAgent.Soul.user()

    parts = []

    parts =
      if identity do
        ["IDENTITY.md: loaded (#{String.length(identity)} chars)" | parts]
      else
        ["IDENTITY.md: using defaults" | parts]
      end

    parts =
      if soul do
        ["SOUL.md: loaded (#{String.length(soul)} chars)" | parts]
      else
        ["SOUL.md: using defaults" | parts]
      end

    parts =
      if user do
        ["USER.md: loaded (#{String.length(user)} chars)" | parts]
      else
        ["USER.md: not found" | parts]
      end

    {:command, "Soul configuration:\n  " <> Enum.join(Enum.reverse(parts), "\n  ")}
  end

  defp cmd_model(arg, _session_id) do
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        cmd_model_show()

      trimmed == "list" ->
        cmd_model_list()

      trimmed == "ollama" ->
        # /model ollama — switch to ollama with current model
        cmd_model_switch("ollama", nil)

      trimmed == "ollama list" or trimmed == "ollama ls" or trimmed == "models" ->
        cmd_ollama_models()

      String.starts_with?(trimmed, "ollama-url ") ->
        url = String.trim(String.trim_leading(trimmed, "ollama-url"))
        cmd_model_set_ollama_url(url)

      String.starts_with?(trimmed, "ollama ") ->
        # /model ollama <model> — switch to specific ollama model
        model = String.trim(String.trim_leading(trimmed, "ollama"))
        cmd_model_switch("ollama", model)

      true ->
        # Parse: <provider> [model]
        case String.split(trimmed, ~r/\s+/, parts: 2) do
          [provider_str, model_str] ->
            cmd_model_switch(provider_str, String.trim(model_str))

          [provider_str] ->
            cmd_model_switch(provider_str, nil)
        end
    end
  end

  defp cmd_model_show do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
    model = active_model_for(provider)
    registry = OptimalSystemAgent.Providers.Registry
    tier_mod = OptimalSystemAgent.Agent.Tier

    configured =
      registry.list_providers()
      |> Enum.filter(&registry.provider_configured?/1)
      |> Enum.map(&to_string/1)
      |> Enum.join(", ")

    # Tier → model routing for current provider
    tier_lines =
      [:elite, :specialist, :utility]
      |> Enum.map(fn tier ->
        tier_model = tier_mod.model_for(tier, provider)
        budget = tier_mod.total_budget(tier)
        temp = tier_mod.temperature(tier)
        iters = tier_mod.max_iterations(tier)

        "  #{String.pad_trailing(to_string(tier), 12)} #{String.pad_trailing(tier_model, 32)} #{budget}t  T=#{temp}  max=#{iters}"
      end)
      |> Enum.join("\n")

    output =
      """
      Active: #{provider} / #{model}

      Tier routing (#{provider}):
      #{tier_lines}

      Configured providers: #{configured}

      Switch:  /model <provider> [model]
      List:    /model list
      Tiers:   /tiers
      Ollama:  /model ollama-url <url>
      """
      |> String.trim()

    {:command, output}
  end

  defp cmd_model_list do
    registry = OptimalSystemAgent.Providers.Registry
    current = Application.get_env(:optimal_system_agent, :default_provider, :unknown)

    lines =
      registry.list_providers()
      |> Enum.sort()
      |> Enum.map(fn p ->
        configured = registry.provider_configured?(p)
        marker = if p == current, do: " *", else: "  "

        {:ok, info} = registry.provider_info(p)
        status = if configured, do: "ready", else: "no key"

        "#{marker}#{String.pad_trailing(to_string(p), 14)} #{String.pad_trailing(info.default_model, 40)} [#{status}]"
      end)

    header = "Providers (* = active):\n"
    footer = "\n\nSwitch: /model <provider> [model]"

    {:command, header <> Enum.join(lines, "\n") <> footer}
  end

  defp cmd_model_switch(provider_str, model_override) do
    provider = String.to_atom(provider_str)
    registry = OptimalSystemAgent.Providers.Registry
    available = registry.list_providers()

    cond do
      provider not in available ->
        {:command,
         "Unknown provider: #{provider_str}\n\nUse /model list to see available providers."}

      not registry.provider_configured?(provider) ->
        key_name = String.upcase("#{provider}_API_KEY")

        {:command,
         "Provider #{provider_str} is not configured.\nSet #{key_name} environment variable and restart, or use /model list."}

      # Fix 1: Validate Ollama model exists before switching
      provider == :ollama and model_override != nil ->
        case validate_ollama_model(model_override) do
          :ok -> do_model_switch(provider, model_override)
          {:warn, msg} -> do_model_switch(provider, model_override, msg)
          {:error, msg} -> {:command, msg}
        end

      true ->
        do_model_switch(provider, model_override)
    end
  end

  defp do_model_switch(provider, model_override, extra_warning \\ nil) do
    Application.put_env(:optimal_system_agent, :default_provider, provider)

    if model_override do
      model_key = :"#{provider}_model"
      Application.put_env(:optimal_system_agent, model_key, model_override)
    end

    model = active_model_for(provider)
    parts = ["Switched to #{provider} / #{model}"]

    # Fix 3: Refresh tier assignments when switching Ollama models
    parts =
      if provider == :ollama do
        Task.start(fn -> OptimalSystemAgent.Agent.Tier.detect_ollama_tiers() end)
        parts ++ ["Refreshing tier assignments..."]
      else
        parts
      end

    # Fix 4: Warn when switched model doesn't support tools
    parts =
      if provider == :ollama and model_override != nil and
           not OptimalSystemAgent.Providers.Ollama.model_supports_tools?(model_override) do
        parts ++
          [
            "⚠ #{model_override} does not support tool calling — tools will be disabled for this model."
          ]
      else
        parts
      end

    parts = if extra_warning, do: parts ++ [extra_warning], else: parts

    {:command, Enum.join(parts, "\n")}
  end

  defp validate_ollama_model(model_name) do
    case OptimalSystemAgent.Providers.Ollama.list_models() do
      {:ok, models} ->
        names = Enum.map(models, & &1.name)

        if model_name in names do
          :ok
        else
          installed = Enum.join(names, ", ")

          {:error,
           "Model '#{model_name}' not found on Ollama.\n\nInstalled: #{installed}\n\nPull it first: ollama pull #{model_name}"}
        end

      {:error, _} ->
        {:warn, "⚠ Could not reach Ollama to verify model — switching anyway."}
    end
  end

  defp cmd_ollama_models do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")
    current_model = Application.get_env(:optimal_system_agent, :ollama_model, "llama3.2:latest")

    case OptimalSystemAgent.Providers.Ollama.list_models(url) do
      {:ok, models} ->
        if models == [] do
          {:command, "No models installed.\n\nPull one: ollama pull llama3.2"}
        else
          lines =
            models
            |> Enum.sort_by(fn m -> m.size end, :desc)
            |> Enum.map(fn m ->
              marker = if m.name == current_model, do: " *", else: "  "
              size_gb = Float.round(m.size / 1_000_000_000, 1)
              "#{marker}#{String.pad_trailing(m.name, 36)} #{size_gb} GB"
            end)

          header = "Ollama models at #{url} (* = active):\n"
          footer = "\n\nSwitch: /model ollama <name>"

          {:command, header <> Enum.join(lines, "\n") <> footer}
        end

      {:error, reason} ->
        {:command,
         "Cannot reach Ollama at #{url}: #{reason}\n\nIs Ollama running? Try: ollama serve"}
    end
  end

  defp cmd_model_set_ollama_url(url) do
    if url == "" do
      current = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")
      {:command, "Current Ollama URL: #{current}\n\nUsage: /model ollama-url <url>"}
    else
      Application.put_env(:optimal_system_agent, :ollama_url, url)
      # Fix 2: Refresh tier assignments when URL changes (new server may have different models)
      Task.start(fn -> OptimalSystemAgent.Agent.Tier.detect_ollama_tiers() end)
      {:command, "Ollama URL set to: #{url}\nRefreshing tier assignments..."}
    end
  end

  defp cmd_models_shortcut(_arg, _session_id) do
    cmd_ollama_models()
  end

  defp active_model_for(provider) do
    model_key = :"#{provider}_model"

    case Application.get_env(:optimal_system_agent, model_key) do
      nil ->
        case OptimalSystemAgent.Providers.Registry.provider_info(provider) do
          {:ok, info} -> info.default_model
          _ -> "unknown"
        end

      model ->
        model
    end
  end

  # ── Session Management ──────────────────────────────────────────

  defp cmd_new(_arg, _session_id) do
    {:action, :new_session, "Starting fresh session..."}
  end

  defp cmd_sessions(_arg, _session_id) do
    sessions = OptimalSystemAgent.Agent.Memory.list_sessions()

    output =
      if sessions == [] do
        "No stored sessions."
      else
        header = "Stored sessions (#{length(sessions)}):\n"

        body =
          sessions
          |> Enum.sort_by(& &1[:last_active], :desc)
          |> Enum.take(20)
          |> Enum.map_join("\n", fn s ->
            id = s[:session_id] || "?"
            msgs = s[:message_count] || 0
            last = format_timestamp(s[:last_active])
            hint = s[:topic_hint] || ""
            hint_str = if hint != "", do: " — #{String.slice(hint, 0, 50)}", else: ""

            "  #{String.pad_trailing(id, 24)} #{String.pad_trailing("#{msgs} msgs", 10)} #{last}#{hint_str}"
          end)

        footer = "\n\nUse /resume <session-id> to continue a session."

        header <> body <> footer
      end

    {:command, output}
  end

  defp cmd_resume(arg, _session_id) do
    target = String.trim(arg)

    if target == "" do
      {:command, "Usage: /resume <session-id>\n\nUse /sessions to see available sessions."}
    else
      case OptimalSystemAgent.Agent.Memory.resume_session(target) do
        {:ok, messages} ->
          {:action, {:resume_session, target, messages},
           "Resuming session #{target} (#{length(messages)} messages)..."}

        {:error, :not_found} ->
          {:command, "Session not found: #{target}\n\nUse /sessions to see available sessions."}
      end
    end
  end

  # ── Channels ─────────────────────────────────────────────────

  defp cmd_channels(arg, _session_id) do
    alias OptimalSystemAgent.Channels.Manager
    parts = String.split(String.trim(arg), ~r/\s+/, parts: 2)

    case parts do
      [""] ->
        cmd_channels_overview()

      ["connect", name] ->
        case resolve_channel_name(name) do
          nil ->
            {:command, "Unknown channel: #{name}\n\nAvailable: #{Enum.join(Manager.known_channels(), ", ")}"}

          channel ->
            case Manager.start_channel(channel) do
              {:ok, pid} ->
                {:command, "Channel #{name} started (pid=#{inspect(pid)})"}

              {:error, :not_configured} ->
                {:command, "Channel #{name} is not configured. Run /setup to configure it."}

              {:error, reason} ->
                {:command, "Failed to start #{name}: #{inspect(reason)}"}
            end
        end

      ["disconnect", name] ->
        case resolve_channel_name(name) do
          nil ->
            {:command, "Unknown channel: #{name}\n\nAvailable: #{Enum.join(Manager.known_channels(), ", ")}"}

          channel ->
            case Manager.stop_channel(channel) do
              :ok ->
                {:command, "Channel #{name} disconnected."}

              {:error, :not_running} ->
                {:command, "Channel #{name} is not running."}

              {:error, reason} ->
                {:command, "Failed to stop #{name}: #{inspect(reason)}"}
            end
        end

      ["status", name] ->
        case resolve_channel_name(name) do
          nil ->
            {:command, "Unknown channel: #{name}"}

          channel ->
            case Manager.channel_status(channel) do
          {:ok, info} ->
            output =
              """
              Channel: #{info.name}
                module:     #{inspect(info.module)}
                pid:        #{inspect(info.pid)}
                connected:  #{info.connected}
                configured: #{info.configured}
              """
              |> String.trim()

            {:command, output}
            end
        end

      ["test", name] ->
        case resolve_channel_name(name) do
          nil ->
            {:command, "Unknown channel: #{name}"}

          channel ->
            case Manager.test_channel(channel) do
              {:ok, :connected} ->
                {:command, "Channel #{name}: connected and responding."}

              {:error, :not_running} ->
                {:command, "Channel #{name}: not running. Use /channels connect #{name}"}

              {:error, :not_connected} ->
                {:command, "Channel #{name}: process alive but not connected."}

              {:error, :process_dead} ->
                {:command, "Channel #{name}: process is dead."}
            end
        end

      _ ->
        {:command,
         "Usage:\n  /channels                    List all channels\n  /channels connect <name>     Start a channel\n  /channels disconnect <name>  Stop a channel\n  /channels status <name>      Detailed status\n  /channels test <name>        Verify responding"}
    end
  end

  defp cmd_channels_overview do
    alias OptimalSystemAgent.Channels.Manager
    channels = Manager.list_channels()
    active = Enum.count(channels, & &1.connected)

    lines =
      Enum.map_join(channels, "\n", fn ch ->
        status = if ch.connected, do: "active", else: "inactive"
        pid_str = if ch.pid, do: inspect(ch.pid), else: "-"

        "  #{String.pad_trailing(to_string(ch.name), 12)} #{String.pad_trailing(status, 10)} #{pid_str}"
      end)

    {:command,
     "Channels (#{active}/#{length(channels)} active):\n  #{String.pad_trailing("NAME", 12)} #{String.pad_trailing("STATUS", 10)} PID\n#{lines}"}
  end

  # Safely resolve a user-typed channel name string to a known atom.
  # Returns nil if the channel name doesn't match any known channel.
  defp resolve_channel_name(name) when is_binary(name) do
    alias OptimalSystemAgent.Channels.Manager
    Enum.find(Manager.known_channels(), fn ch -> to_string(ch) == name end)
  end

  # ── WhatsApp ────────────────────────────────────────────────

  defp cmd_whatsapp(arg, _session_id) do
    parts = String.split(String.trim(arg), ~r/\s+/, parts: 2)

    case parts do
      [""] -> cmd_whatsapp_status()
      ["connect"] -> cmd_whatsapp_connect()
      ["disconnect"] -> cmd_whatsapp_disconnect()
      ["test"] -> cmd_whatsapp_test()

      _ ->
        {:command,
         "Usage:\n  /whatsapp             Status\n  /whatsapp connect     Connect via QR code\n  /whatsapp disconnect  Logout + stop\n  /whatsapp test        Verify connection"}
    end
  end

  defp cmd_whatsapp_status do
    mode = Application.get_env(:optimal_system_agent, :whatsapp_mode, "auto")
    api_configured = Application.get_env(:optimal_system_agent, :whatsapp_token) != nil
    web_available = OptimalSystemAgent.WhatsAppWeb.available?()

    web_state =
      if web_available do
        case OptimalSystemAgent.WhatsAppWeb.connection_status() do
          {:ok, %{"connection" => conn, "jid" => jid}} ->
            "#{conn}#{if jid, do: " (#{jid})", else: ""}"

          _ ->
            "unknown"
        end
      else
        "sidecar not available"
      end

    output =
      """
      WhatsApp Status:
        mode:          #{mode}
        API (Cloud):   #{if api_configured, do: "configured", else: "not configured"}
        Web (Baileys): #{web_state}
      """
      |> String.trim()

    {:command, output}
  end

  defp cmd_whatsapp_connect do
    if not OptimalSystemAgent.WhatsAppWeb.available?() do
      {:command,
       "WhatsApp Web sidecar is not available.\nEnsure Node.js is installed and run: cd priv/sidecar/baileys && npm install"}
    else
      case OptimalSystemAgent.WhatsAppWeb.connect() do
        {:ok, %{"status" => "qr", "qr_text" => qr_text}}
        when is_binary(qr_text) and qr_text != "" ->
          {:command, "Scan this QR code with WhatsApp:\n\n#{qr_text}\n\nWaiting for scan..."}

        {:ok, %{"status" => "qr", "qr" => _qr}} ->
          {:command, "QR code generated but text rendering failed. Check sidecar logs."}

        {:ok, %{"status" => "connected", "jid" => jid}} ->
          {:command, "Already connected as #{jid}"}

        {:ok, %{"status" => "logged_out"}} ->
          {:command, "Session was logged out. Try /whatsapp connect again."}

        {:error, reason} ->
          {:command, "Failed to connect: #{inspect(reason)}"}
      end
    end
  end

  defp cmd_whatsapp_disconnect do
    if not OptimalSystemAgent.WhatsAppWeb.available?() do
      {:command, "WhatsApp Web sidecar is not running."}
    else
      case OptimalSystemAgent.WhatsAppWeb.logout() do
        {:ok, _} -> {:command, "WhatsApp Web disconnected and session cleared."}
        {:error, reason} -> {:command, "Disconnect failed: #{inspect(reason)}"}
      end
    end
  end

  defp cmd_whatsapp_test do
    api_ok =
      case OptimalSystemAgent.Channels.WhatsApp.connected?() do
        true -> "connected"
        false -> "not connected"
      end

    web_ok =
      if OptimalSystemAgent.WhatsAppWeb.available?() do
        case OptimalSystemAgent.WhatsAppWeb.health_check() do
          :ready -> "connected"
          :degraded -> "degraded (awaiting QR scan)"
          _ -> "not available"
        end
      else
        "sidecar not running"
      end

    {:command, "WhatsApp Test:\n  API (Cloud):   #{api_ok}\n  Web (Baileys): #{web_ok}"}
  end

  # ── History ──────────────────────────────────────────────────

  defp cmd_history(arg, _session_id) do
    {channel_filter, trimmed} = extract_channel_flag(String.trim(arg))

    cond do
      trimmed == "" ->
        cmd_history_list(channel_filter)

      String.starts_with?(trimmed, "search ") ->
        query = String.trim_leading(trimmed, "search ") |> String.trim()
        cmd_history_search(query, channel_filter)

      true ->
        cmd_history_session(trimmed, channel_filter)
    end
  end

  defp extract_channel_flag(arg) do
    case Regex.run(~r/--channel\s+(\S+)/, arg) do
      [match, channel] ->
        rest = String.replace(arg, match, "") |> String.trim()
        {channel, rest}

      nil ->
        {nil, arg}
    end
  end

  defp cmd_history_list(channel_filter) do
    import Ecto.Query
    alias OptimalSystemAgent.Store.{Repo, Message}

    base_query =
      from(m in Message,
        group_by: m.session_id,
        order_by: [desc: max(m.inserted_at)],
        limit: 20,
        select: %{
          session_id: m.session_id,
          count: count(m.id),
          last_at: max(m.inserted_at)
        }
      )

    query =
      if channel_filter do
        from(m in base_query, where: m.channel == ^channel_filter)
      else
        base_query
      end

    sessions = Repo.all(query)

    filter_label = if channel_filter, do: " (channel: #{channel_filter})", else: ""

    if sessions == [] do
      {:command,
       "No message history found#{filter_label}. Messages will be stored after your next conversation."}
    else
      lines =
        Enum.map_join(sessions, "\n", fn s ->
          last = if s.last_at, do: NaiveDateTime.to_string(s.last_at), else: "unknown"

          "  #{String.pad_trailing(s.session_id, 36)} #{String.pad_leading(to_string(s.count), 5)} msgs  #{last}"
        end)

      {:command,
       "Recent sessions#{filter_label}:\n#{lines}\n\n  /history <session_id>    Browse messages\n  /history search <query>  Search all messages\n  /history --channel <ch>  Filter by channel"}
    end
  rescue
    _ ->
      sessions = OptimalSystemAgent.Agent.Memory.list_sessions()

      lines =
        Enum.map_join(Enum.take(sessions, 20), "\n", fn s ->
          "  #{String.pad_trailing(s.session_id, 36)} #{String.pad_leading(to_string(s.message_count), 5)} msgs"
        end)

      {:command, "Recent sessions (from files):\n#{lines}"}
  end

  defp cmd_history_session(session_id, channel_filter) do
    import Ecto.Query
    alias OptimalSystemAgent.Store.{Repo, Message}

    base_query =
      from(m in Message,
        where: m.session_id == ^session_id,
        order_by: [asc: m.inserted_at],
        limit: 50,
        select: %{role: m.role, content: m.content, channel: m.channel, inserted_at: m.inserted_at}
      )

    query =
      if channel_filter do
        from(m in base_query, where: m.channel == ^channel_filter)
      else
        base_query
      end

    messages = Repo.all(query)

    filter_label = if channel_filter, do: " [#{channel_filter}]", else: ""

    if messages == [] do
      {:command, "No messages found for session: #{session_id}#{filter_label}"}
    else
      lines =
        Enum.map_join(messages, "\n", fn m ->
          time = if m.inserted_at, do: NaiveDateTime.to_string(m.inserted_at), else: ""
          role = String.pad_trailing(m.role, 10)
          ch = if m.channel, do: String.pad_trailing(m.channel, 10), else: String.pad_trailing("", 10)
          content = String.slice(m.content || "", 0, 100)
          "  #{time}  #{role}  #{ch}  #{content}"
        end)

      {:command, "Session #{session_id}#{filter_label} (#{length(messages)} messages):\n#{lines}"}
    end
  rescue
    _ -> {:command, "Error loading session: #{session_id}"}
  end

  defp cmd_history_search(query, channel_filter) do
    import Ecto.Query
    alias OptimalSystemAgent.Store.{Repo, Message}

    limit = 20
    pattern = "%#{query}%"

    base_query =
      from(m in Message,
        where: like(m.content, ^pattern),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        select: %{
          id: m.id,
          session_id: m.session_id,
          role: m.role,
          content: m.content,
          channel: m.channel,
          inserted_at: m.inserted_at
        }
      )

    q =
      if channel_filter do
        from(m in base_query, where: m.channel == ^channel_filter)
      else
        base_query
      end

    results = Repo.all(q)

    filter_label = if channel_filter, do: " [#{channel_filter}]", else: ""

    if results == [] do
      {:command, "No messages matching: #{query}#{filter_label}"}
    else
      lines =
        Enum.map_join(results, "\n", fn m ->
          time = if m.inserted_at, do: NaiveDateTime.to_string(m.inserted_at), else: ""
          sid = String.slice(m.session_id, 0, 12)
          ch = if m[:channel], do: " [#{m[:channel]}]", else: ""
          content = String.slice(m.content || "", 0, 100)
          "  #{sid}  #{time}#{ch}  #{content}"
        end)

      {:command, "Search results for \"#{query}\"#{filter_label} (#{length(results)}):\n#{lines}"}
    end
  rescue
    _ ->
      # Fall back to Memory module search (no channel filter)
      results = OptimalSystemAgent.Agent.Memory.search_messages(query, limit: 20)

      if results == [] do
        {:command, "No messages matching: #{query}"}
      else
        lines =
          Enum.map_join(results, "\n", fn m ->
            time = if m.inserted_at, do: NaiveDateTime.to_string(m.inserted_at), else: ""
            sid = String.slice(m.session_id, 0, 12)
            content = String.slice(m.content || "", 0, 100)
            "  #{sid}  #{time}  #{content}"
          end)

        {:command, "Search results for \"#{query}\" (#{length(results)}):\n#{lines}"}
      end
  end

  # ── Context & Performance ─────────────────────────────────────

  defp cmd_compact(_arg, _session_id) do
    stats = OptimalSystemAgent.Agent.Compactor.stats()

    output =
      """
      Context Compactor:
        compactions:     #{stats[:compaction_count] || 0}
        tokens saved:    #{stats[:tokens_saved] || 0}
        last compacted:  #{format_timestamp(stats[:last_compacted_at])}
        pipeline steps:  #{format_pipeline_steps(stats[:pipeline_steps_used])}
      """
      |> String.trim()

    {:command, output}
  end

  defp cmd_usage(_arg, _session_id) do
    compactor_stats = OptimalSystemAgent.Agent.Compactor.stats()
    memory_stats = OptimalSystemAgent.Agent.Memory.memory_stats()
    max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)

    output =
      """
      Token Usage:
        max context:     #{format_number(max_tokens)} tokens
        tokens saved:    #{format_number(compactor_stats[:tokens_saved] || 0)} (via compaction)
        compactions:     #{compactor_stats[:compaction_count] || 0}
        sessions stored: #{memory_stats[:session_count] || 0}
        memory on disk:  #{format_bytes(memory_stats[:long_term_size] || 0)}
      """
      |> String.trim()

    {:command, output}
  end

  # ── Intelligence ──────────────────────────────────────────────

  defp cmd_cortex(_arg, _session_id) do
    bulletin = OptimalSystemAgent.Agent.Cortex.bulletin()
    topics = OptimalSystemAgent.Agent.Cortex.active_topics()
    stats = OptimalSystemAgent.Agent.Cortex.synthesis_stats()

    parts = []

    parts =
      if bulletin do
        ["Bulletin:\n#{indent(bulletin, 4)}" | parts]
      else
        ["Bulletin: (not yet generated — waiting for first synthesis cycle)" | parts]
      end

    parts =
      if topics != [] do
        topic_list =
          topics
          |> Enum.take(10)
          |> Enum.map_join("\n", fn t ->
            "    #{t[:topic] || t.topic}  (#{t[:frequency] || t.frequency}x)"
          end)

        ["Active topics:\n#{topic_list}" | parts]
      else
        parts
      end

    parts = [
      "Stats: last refresh #{format_timestamp(stats[:last_refresh])}, #{stats[:bulletin_bytes] || 0} bytes, #{stats[:active_topic_count] || 0} topics"
      | parts
    ]

    {:command, Enum.reverse(parts) |> Enum.join("\n\n")}
  end

  # ── Configuration ─────────────────────────────────────────────

  defp cmd_verbose(_arg, session_id) do
    current = get_setting(session_id, :verbose, false)
    new_value = !current
    put_setting(session_id, :verbose, new_value)
    {:command, "Verbose mode: #{if new_value, do: "on", else: "off"}"}
  end

  defp cmd_plan(_arg, session_id) do
    case GenServer.call(
           {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id}},
           :toggle_plan_mode
         ) do
      {:ok, true} ->
        {:command, "Plan mode enabled — complex tasks will show plans for approval"}

      {:ok, false} ->
        {:command, "Plan mode disabled — all tasks execute immediately"}
    end
  rescue
    _ -> {:command, "Plan mode toggle failed — no active session"}
  end

  defp cmd_think(arg, session_id) do
    level = String.trim(arg) |> String.downcase()

    case level do
      "" ->
        current = get_setting(session_id, :think_level, "normal")
        {:command, "Current reasoning depth: #{current}\n\nUsage: /think fast|normal|deep"}

      l when l in ["fast", "normal", "deep"] ->
        put_setting(session_id, :think_level, l)

        desc =
          case l do
            "fast" -> "quick responses, minimal deliberation"
            "normal" -> "balanced reasoning and speed"
            "deep" -> "thorough analysis, extended thinking"
          end

        {:command, "Reasoning depth: #{l} (#{desc})"}

      _ ->
        {:command, "Unknown level: #{level}\n\nUsage: /think fast|normal|deep"}
    end
  end

  defp cmd_config(_arg, session_id) do
    verbose = get_setting(session_id, :verbose, false)
    think = get_setting(session_id, :think_level, "normal")
    provider = Application.get_env(:optimal_system_agent, :default_provider, "unknown")
    max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
    max_iter = Application.get_env(:optimal_system_agent, :max_iterations, 30)
    http_port = Application.get_env(:optimal_system_agent, :http_port, 8089)
    sandbox = Application.get_env(:optimal_system_agent, :sandbox_enabled, false)

    output =
      """
      Runtime Configuration:
        session:       #{session_id}
        verbose:       #{verbose}
        think level:   #{think}
        provider:      #{provider}
        max tokens:    #{format_number(max_tokens)}
        max iterations: #{max_iter}
        http port:     #{http_port}
        sandbox:       #{sandbox}
      """
      |> String.trim()

    {:command, output}
  end

  # ── System ────────────────────────────────────────────────────

  defp cmd_reload(_arg, _session_id) do
    OptimalSystemAgent.Soul.reload()
    OptimalSystemAgent.PromptLoader.load()
    {:command, "Soul + prompt files reloaded from disk."}
  end

  defp cmd_doctor(_arg, _session_id) do
    checks = [
      check_soul(),
      check_providers(),
      check_skills(),
      check_memory(),
      check_cortex(),
      check_scheduler(),
      check_http()
    ]

    passed = Enum.count(checks, fn {status, _, _} -> status == :ok end)
    total = length(checks)

    header = "System Diagnostics (#{passed}/#{total} passed):\n"

    body =
      Enum.map_join(checks, "\n", fn {status, name, detail} ->
        icon =
          case status do
            :ok -> "[ok]"
            :warn -> "[!!]"
            :fail -> "[XX]"
          end

        "  #{icon} #{String.pad_trailing(name, 20)} #{detail}"
      end)

    {:command, header <> body}
  end

  defp cmd_setup(_arg, _session_id) do
    OptimalSystemAgent.Onboarding.Channels.run()
    {:command, "Channel setup complete."}
  end

  # ── Agent Ecosystem Commands ──────────────────────────────────

  defp cmd_agents(arg, _session_id) do
    alias OptimalSystemAgent.Agent.Roster

    if arg != "" and String.trim(arg) != "" do
      # Show detail for a specific agent
      case Roster.get(String.trim(arg)) do
        nil ->
          {:command, "Unknown agent: #{arg}\nUse /agents to list all."}

        agent ->
          output = """
          #{agent.name} (#{agent.tier})
            Role: #{agent.role}
            #{agent.description}

            Skills: #{Enum.join(agent.skills, ", ")}
            Triggers: #{Enum.join(agent.triggers, ", ")}
            Territory: #{Enum.join(agent.territory, ", ")}
            Escalates to: #{agent.escalate_to || "none"}
          """

          {:command, String.trim(output)}
      end
    else
      agents = Roster.all()

      elite =
        agents |> Map.values() |> Enum.filter(&(&1.tier == :elite)) |> Enum.sort_by(& &1.name)

      specialist =
        agents
        |> Map.values()
        |> Enum.filter(&(&1.tier == :specialist))
        |> Enum.sort_by(& &1.name)

      utility =
        agents |> Map.values() |> Enum.filter(&(&1.tier == :utility)) |> Enum.sort_by(& &1.name)

      format_tier = fn tier_agents ->
        Enum.map_join(tier_agents, "\n", fn a ->
          "  #{String.pad_trailing(a.name, 22)} #{a.description}"
        end)
      end

      output = """
      Agent Roster (#{map_size(agents)} agents)

      ELITE (opus):
      #{format_tier.(elite)}

      SPECIALIST (sonnet):
      #{format_tier.(specialist)}

      UTILITY (haiku):
      #{format_tier.(utility)}

      Use /agents <name> for details.
      """

      {:command, String.trim(output)}
    end
  end

  defp cmd_tiers(_arg, _session_id) do
    alias OptimalSystemAgent.Agent.Tier

    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    output = """
    Model Tiers (provider: #{provider})

    Elite (opus-class):
      Model: #{Tier.model_for(:elite, provider)}
      Budget: #{Tier.total_budget(:elite)} tokens
      Max agents: #{Tier.max_agents(:elite)}
      Max iterations: #{Tier.max_iterations(:elite)}

    Specialist (sonnet-class):
      Model: #{Tier.model_for(:specialist, provider)}
      Budget: #{Tier.total_budget(:specialist)} tokens
      Max agents: #{Tier.max_agents(:specialist)}
      Max iterations: #{Tier.max_iterations(:specialist)}

    Utility (haiku-class):
      Model: #{Tier.model_for(:utility, provider)}
      Budget: #{Tier.total_budget(:utility)} tokens
      Max agents: #{Tier.max_agents(:utility)}
      Max iterations: #{Tier.max_iterations(:utility)}
    """

    {:command, String.trim(output)}
  end

  defp cmd_swarms(_arg, _session_id) do
    alias OptimalSystemAgent.Agent.Roster

    presets = Roster.swarm_presets()

    lines =
      Enum.map_join(presets, "\n", fn {name, preset} ->
        agents_str = Enum.join(preset.agents, ", ")
        "  #{String.pad_trailing(name, 20)} #{preset.pattern} — #{agents_str}"
      end)

    output = """
    Swarm Presets (#{map_size(presets)})

    #{lines}

    Use: /swarm <preset> to launch a swarm (coming soon)
    """

    {:command, String.trim(output)}
  end

  defp cmd_hooks(_arg, _session_id) do
    try do
      hooks = OptimalSystemAgent.Agent.Hooks.list_hooks()
      metrics = OptimalSystemAgent.Agent.Hooks.metrics()

      hook_lines =
        Enum.map_join(hooks, "\n", fn {event, entries} ->
          entry_strs = Enum.map_join(entries, ", ", fn e -> "#{e.name}(p#{e.priority})" end)
          "  #{String.pad_trailing(to_string(event), 18)} #{entry_strs}"
        end)

      metrics_lines =
        Enum.map_join(metrics, "\n", fn {event, m} ->
          "  #{String.pad_trailing(to_string(event), 18)} #{m.calls} calls, avg #{m[:avg_us] || 0}μs, #{m.blocks} blocks"
        end)

      output = """
      Hook Pipeline

      Registered:
      #{hook_lines}

      Metrics:
      #{if metrics_lines == "", do: "  (no data yet)", else: metrics_lines}
      """

      {:command, String.trim(output)}
    rescue
      _ -> {:command, "Hook pipeline not initialized yet."}
    end
  end

  defp cmd_learning(_arg, _session_id) do
    try do
      metrics = OptimalSystemAgent.Agent.Learning.metrics()
      patterns = OptimalSystemAgent.Agent.Learning.patterns()

      top_patterns =
        patterns
        |> Enum.sort_by(fn {_k, v} -> v.count end, :desc)
        |> Enum.take(10)
        |> Enum.map_join("\n", fn {key, info} ->
          "  #{String.pad_trailing(key, 30)} #{info.count}x"
        end)

      output = """
      Learning Engine (SICA)

      Metrics:
        Total interactions: #{metrics.total_interactions}
        Patterns captured:  #{metrics.patterns_captured}
        Skills generated:   #{metrics.skills_generated}
        Errors recovered:   #{metrics.errors_recovered}
        Consolidations:     #{metrics.consolidations}

      Top Patterns:
      #{if top_patterns == "", do: "  (none yet — interact more)", else: top_patterns}
      """

      {:command, String.trim(output)}
    rescue
      _ -> {:command, "Learning engine not initialized yet."}
    end
  end

  # ── Workflow Commands (prompt expansion from priv/commands/workflow/) ──

  defp cmd_workflow(arg, _session_id) do
    # The command name is extracted from the original input by execute/2
    # We need to figure out which workflow command was invoked
    # The handler is called with arg and session_id — but we need the cmd name
    # It's available via the call path in execute/2
    # Workaround: store the last command name in process dictionary during execute
    cmd_name = Process.get(:osa_current_cmd, "unknown")

    case OptimalSystemAgent.PromptLoader.get_command("workflow", cmd_name) do
      nil ->
        {:command, "Workflow command '#{cmd_name}' template not found."}

      template ->
        expanded =
          if arg != "" and String.trim(arg) != "" do
            template <> "\n\nAdditional context: " <> arg
          else
            template
          end

        {:prompt, expanded}
    end
  end

  # ── Context Priming (prompt expansion from priv/commands/context/) ──

  defp cmd_prime(arg, _session_id) do
    cmd_name = Process.get(:osa_current_cmd, "prime")

    case OptimalSystemAgent.PromptLoader.get_command("context", cmd_name) do
      nil ->
        # /prime with no match shows what's loaded
        loaded = OptimalSystemAgent.PromptLoader.list_command_prompts()
        context_cmds = loaded |> Enum.filter(fn {cat, _} -> cat == "context" end)

        if context_cmds == [] do
          {:command, "No context prompts loaded. Check priv/commands/context/"}
        else
          lines = Enum.map_join(context_cmds, "\n", fn {_, name} -> "  /#{name}" end)
          {:command, "Available context priming:\n#{lines}"}
        end

      template ->
        expanded =
          if arg != "" and String.trim(arg) != "" do
            template <> "\n\nFocus on: " <> arg
          else
            template
          end

        {:prompt, expanded}
    end
  end

  # ── Security Commands (prompt expansion from priv/commands/security/) ──

  defp cmd_security(arg, _session_id) do
    cmd_name = Process.get(:osa_current_cmd, "security-scan")

    case OptimalSystemAgent.PromptLoader.get_command("security", cmd_name) do
      nil ->
        {:command, "Security command '#{cmd_name}' template not found."}

      template ->
        expanded =
          if arg != "" and String.trim(arg) != "" do
            template <> "\n\nTarget: " <> arg
          else
            template
          end

        {:prompt, expanded}
    end
  end

  # ── Memory Commands (prompt expansion from priv/commands/memory/) ──

  defp cmd_memory_cmd(arg, _session_id) do
    cmd_name = Process.get(:osa_current_cmd, "mem-search")

    case OptimalSystemAgent.PromptLoader.get_command("memory", cmd_name) do
      nil ->
        {:command, "Memory command '#{cmd_name}' template not found."}

      template ->
        expanded =
          if arg != "" and String.trim(arg) != "" do
            template <> "\n\nQuery: " <> arg
          else
            template
          end

        {:prompt, expanded}
    end
  end

  # ── Scheduler Commands ──────────────────────────────────────────────

  defp cmd_schedule(_arg, _session_id) do
    alias OptimalSystemAgent.Agent.Scheduler

    case Scheduler.status() do
      %{} = s ->
        next_str = Calendar.strftime(s.next_heartbeat, "%Y-%m-%dT%H:%M:%SZ")
        diff_sec = DateTime.diff(s.next_heartbeat, DateTime.utc_now())
        in_str = format_duration(diff_sec)

        output =
          """
          Scheduler:
            Cron jobs:    #{s.cron_active} active (#{s.cron_total} total)
            Triggers:     #{s.trigger_active} active (#{s.trigger_total} total)
            Heartbeat:    #{s.heartbeat_pending} pending tasks
            Next beat:    #{next_str} (#{in_str})
          """
          |> String.trim()

        {:command, output}
    end
  rescue
    _ -> {:command, "Scheduler not available."}
  end

  defp cmd_cron(arg, _session_id) do
    alias OptimalSystemAgent.Agent.Scheduler
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        jobs = Scheduler.list_jobs()

        if jobs == [] do
          {:command, "No cron jobs configured.\n\nUse /cron add to create one."}
        else
          lines =
            Enum.map_join(jobs, "\n", fn job ->
              status =
                cond do
                  job["circuit_open"] -> "circuit-open"
                  job["enabled"] -> "enabled"
                  true -> "disabled"
                end

              "  #{String.pad_trailing(job["id"] || "?", 12)} " <>
                "#{String.pad_trailing(job["name"] || "", 24)} " <>
                "#{String.pad_trailing(job["schedule"] || "", 16)} [#{status}]"
            end)

          header = "Cron jobs (#{length(jobs)}):\n"
          footer = "\n\nCommands: /cron add | run | enable | disable | remove <id>"
          {:command, header <> lines <> footer}
        end

      trimmed == "add" ->
        {:prompt,
         "Create a new cron job. Provide: name, schedule (cron expression), type (agent/command/webhook), and the task/command/url."}

      String.starts_with?(trimmed, "remove ") ->
        id = String.trim(String.trim_leading(trimmed, "remove"))

        case Scheduler.remove_job(id) do
          :ok -> {:command, "Removed cron job: #{id}"}
          {:error, reason} -> {:command, "Failed: #{reason}"}
        end

      String.starts_with?(trimmed, "enable ") ->
        id = String.trim(String.trim_leading(trimmed, "enable"))

        case Scheduler.toggle_job(id, true) do
          :ok -> {:command, "Enabled cron job: #{id}"}
          {:error, reason} -> {:command, "Failed: #{reason}"}
        end

      String.starts_with?(trimmed, "disable ") ->
        id = String.trim(String.trim_leading(trimmed, "disable"))

        case Scheduler.toggle_job(id, false) do
          :ok -> {:command, "Disabled cron job: #{id}"}
          {:error, reason} -> {:command, "Failed: #{reason}"}
        end

      String.starts_with?(trimmed, "run ") ->
        id = String.trim(String.trim_leading(trimmed, "run"))

        case Scheduler.run_job(id) do
          {:ok, _result} -> {:command, "Cron job '#{id}' executed successfully."}
          {:error, reason} -> {:command, "Failed: #{reason}"}
        end

      true ->
        {:command,
         "Unknown cron subcommand: #{trimmed}\n\nUsage: /cron [add | run | enable | disable | remove] <id>"}
    end
  rescue
    _ -> {:command, "Scheduler not available."}
  end

  defp cmd_triggers(arg, _session_id) do
    alias OptimalSystemAgent.Agent.Scheduler
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        triggers = Scheduler.list_triggers()

        if triggers == [] do
          {:command, "No triggers configured.\n\nUse /triggers add to create one."}
        else
          lines =
            Enum.map_join(triggers, "\n", fn t ->
              status =
                cond do
                  t["circuit_open"] -> "circuit-open"
                  t["enabled"] -> "enabled"
                  true -> "disabled"
                end

              "  #{String.pad_trailing(t["id"] || "?", 12)} " <>
                "#{String.pad_trailing(t["name"] || "", 24)} " <>
                "#{String.pad_trailing(t["event"] || "", 16)} [#{status}]"
            end)

          header = "Triggers (#{length(triggers)}):\n"
          footer = "\n\nCommands: /triggers add | remove <id>"
          {:command, header <> lines <> footer}
        end

      trimmed == "add" ->
        {:prompt,
         "Create a new event trigger. Provide: name, event to watch for, type (agent/command), and the action (job description or command)."}

      String.starts_with?(trimmed, "remove ") ->
        id = String.trim(String.trim_leading(trimmed, "remove"))

        case Scheduler.remove_trigger(id) do
          :ok -> {:command, "Removed trigger: #{id}"}
          {:error, reason} -> {:command, "Failed: #{reason}"}
        end

      true ->
        {:command,
         "Unknown triggers subcommand: #{trimmed}\n\nUsage: /triggers [add | remove <id>]"}
    end
  rescue
    _ -> {:command, "Scheduler not available."}
  end

  defp cmd_heartbeat(arg, _session_id) do
    alias OptimalSystemAgent.Agent.Scheduler
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        path = Scheduler.heartbeat_path()

        content =
          case File.read(path) do
            {:ok, c} -> c
            _ -> "(file not found)"
          end

        next = Scheduler.next_heartbeat_at()
        next_str = Calendar.strftime(next, "%Y-%m-%dT%H:%M:%SZ")
        diff_sec = DateTime.diff(next, DateTime.utc_now())
        in_str = format_duration(diff_sec)

        output =
          """
          #{String.trim(content)}

          Next heartbeat: #{next_str} (#{in_str})
          """
          |> String.trim()

        {:command, output}

      String.starts_with?(trimmed, "add ") ->
        text = String.trim(String.trim_leading(trimmed, "add"))

        if text == "" do
          {:command, "Usage: /heartbeat add <task description>"}
        else
          case Scheduler.add_heartbeat_task(text) do
            :ok -> {:command, "Added heartbeat task: #{text}"}
            {:error, reason} -> {:command, "Failed: #{reason}"}
          end
        end

      true ->
        {:command, "Unknown heartbeat subcommand: #{trimmed}\n\nUsage: /heartbeat [add <task>]"}
    end
  rescue
    _ -> {:command, "Scheduler not available."}
  end

  defp format_duration(seconds) when seconds < 0, do: "now"
  defp format_duration(seconds) when seconds < 60, do: "in #{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "in #{div(seconds, 60)} min"

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    "in #{hours}h #{mins}m"
  end

  # ── Task Tracker ──────────────────────────────────────────────

  defp cmd_tasks(arg, session_id) do
    alias OptimalSystemAgent.Agent.TaskTracker
    alias OptimalSystemAgent.Channels.CLI.TaskDisplay
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        tasks = TaskTracker.get_tasks(session_id)

        if tasks == [] do
          {:command, "No tracked tasks. Use /tasks add \"title\" or let OSA auto-detect."}
        else
          {:command, TaskDisplay.render(tasks)}
        end

      trimmed == "clear" ->
        TaskTracker.clear_tasks(session_id)
        {:command, "Tasks cleared."}

      trimmed == "compact" ->
        tasks = TaskTracker.get_tasks(session_id)
        if tasks == [], do: {:command, "No tasks."}, else: {:command, TaskDisplay.render_compact(tasks)}

      trimmed == "inline" ->
        tasks = TaskTracker.get_tasks(session_id)
        if tasks == [], do: {:command, "No tasks."}, else: {:command, TaskDisplay.render_inline(tasks)}

      String.starts_with?(trimmed, "add ") ->
        title = trimmed |> String.trim_leading("add ") |> String.trim() |> String.trim("\"")

        if title == "" do
          {:command, "Usage: /tasks add \"title\""}
        else
          {:ok, id} = TaskTracker.add_task(session_id, title)
          {:command, "Added task #{id}: #{title}"}
        end

      true ->
        {:command,
         "Unknown subcommand: #{trimmed}\n\nUsage:\n  /tasks           — show task panel\n  /tasks add \"t\"   — add a task\n  /tasks clear     — clear all tasks\n  /tasks compact   — single-line view\n  /tasks inline    — Claude Code-style view"}
    end
  rescue
    _ -> {:command, "Task tracker not available."}
  end

  # ── Utility Commands (prompt expansion from priv/commands/utility/) ──

  defp cmd_utility(arg, _session_id) do
    cmd_name = Process.get(:osa_current_cmd, "unknown")

    case OptimalSystemAgent.PromptLoader.get_command("utility", cmd_name) do
      nil ->
        {:command, "Utility command '#{cmd_name}' template not found."}

      template ->
        expanded =
          if arg != "" and String.trim(arg) != "" do
            template <> "\n\nContext: " <> arg
          else
            template
          end

        {:prompt, expanded}
    end
  end

  defp cmd_exit(_arg, _session_id) do
    {:action, :exit, ""}
  end

  defp cmd_clear(_arg, _session_id) do
    {:action, :clear, ""}
  end

  defp cmd_create(arg, _session_id) do
    result =
      case parse_create_args(arg) do
        {:ok, name, description, template} ->
          case register(name, description, template) do
            :ok -> "Created command /#{name} — try it out!"
            {:error, reason} -> "Failed: #{reason}"
          end

        :help ->
          """
          Usage: /create-command name | description | template

          Example:
            /create-command standup | Daily standup summary | Review my recent activity and generate a standup update. Include what I did, what I'm doing, and any blockers.

          The template becomes the prompt sent to the agent when the command is used.
          """
          |> String.trim()
      end

    {:command, result}
  end

  defp parse_create_args(""), do: :help

  defp parse_create_args(arg) do
    case String.split(arg, "|", parts: 3) do
      [name, desc, template] ->
        {:ok, String.trim(name), String.trim(desc), String.trim(template)}

      [name, template] ->
        {:ok, String.trim(name), "Custom command", String.trim(template)}

      _ ->
        :help
    end
  end

  # ── Doctor Checks ──────────────────────────────────────────────

  defp check_soul do
    identity = OptimalSystemAgent.Soul.identity()
    soul = OptimalSystemAgent.Soul.soul()

    cond do
      identity && soul -> {:ok, "Soul", "identity + soul loaded"}
      identity -> {:warn, "Soul", "identity loaded, soul using defaults"}
      soul -> {:warn, "Soul", "soul loaded, identity using defaults"}
      true -> {:warn, "Soul", "using defaults (no ~/.osa/IDENTITY.md or SOUL.md)"}
    end
  end

  defp check_providers do
    providers = OptimalSystemAgent.Providers.Registry.list_providers()

    if length(providers) > 0 do
      {:ok, "Providers", "#{length(providers)} loaded"}
    else
      {:fail, "Providers", "no LLM providers available"}
    end
  end

  defp check_skills do
    skills = OptimalSystemAgent.Skills.Registry.list_tools_direct()

    cond do
      length(skills) >= 5 -> {:ok, "Skills", "#{length(skills)} available"}
      length(skills) > 0 -> {:warn, "Skills", "#{length(skills)} available (low)"}
      true -> {:fail, "Skills", "no skills loaded"}
    end
  end

  defp check_memory do
    stats = OptimalSystemAgent.Agent.Memory.memory_stats()
    count = stats[:entry_count] || stats[:session_count] || 0

    if count >= 0 do
      {:ok, "Memory",
       "#{stats[:session_count] || 0} sessions, #{stats[:entry_count] || 0} entries"}
    else
      {:warn, "Memory", "no data yet"}
    end
  end

  defp check_cortex do
    stats = OptimalSystemAgent.Agent.Cortex.synthesis_stats()

    if stats[:has_bulletin] do
      {:ok, "Cortex", "bulletin active, #{stats[:active_topic_count] || 0} topics"}
    else
      {:warn, "Cortex", "no bulletin yet (will generate on first cycle)"}
    end
  end

  defp check_scheduler do
    # Check if scheduler process is alive
    case Process.whereis(OptimalSystemAgent.Agent.Scheduler) do
      nil -> {:fail, "Scheduler", "not running"}
      pid when is_pid(pid) -> {:ok, "Scheduler", "running (pid #{inspect(pid)})"}
    end
  end

  defp check_http do
    port = Application.get_env(:optimal_system_agent, :http_port, 8089)
    {:ok, "HTTP", "listening on port #{port}"}
  end

  # ── Formatting Helpers ────────────────────────────────────────

  defp format_timestamp(nil), do: "never"
  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_timestamp(str) when is_binary(str), do: str
  defp format_timestamp(_), do: "unknown"

  defp format_categories(nil), do: "none"

  defp format_categories(cats) when is_map(cats) do
    cats
    |> Enum.map_join(", ", fn {k, v} -> "#{k}:#{v}" end)
  end

  defp format_categories(_), do: "none"

  defp format_pipeline_steps(nil), do: "none"
  defp format_pipeline_steps(steps) when is_map(steps) and map_size(steps) == 0, do: "none"

  defp format_pipeline_steps(steps) when is_map(steps) do
    steps
    |> Enum.map_join(", ", fn {k, v} -> "#{k}:#{v}" end)
  end

  defp format_pipeline_steps(_), do: "none"

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: "#{n}"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} bytes"
  defp format_bytes(_), do: "0 bytes"

  defp indent(text, spaces) do
    pad = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> pad <> line end)
  end

  # ── Custom Command Persistence ─────────────────────────────────

  defp load_custom_commands do
    dir = Path.expand(commands_dir())

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.each(fn filename ->
        path = Path.join(dir, filename)

        case parse_command_file(path) do
          {:ok, name, description, template} ->
            :ets.insert(@ets_table, {name, template, description})

          :error ->
            Logger.warning("[Commands] Failed to parse: #{path}")
        end
      end)
    end
  rescue
    e ->
      Logger.warning("[Commands] Failed to load custom commands: #{Exception.message(e)}")
  end

  defp parse_command_file(path) do
    content = File.read!(path)

    case String.split(content, "---", parts: 3) do
      ["", frontmatter, body] ->
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, meta} ->
            name = meta["name"] || Path.basename(path, ".md")
            description = meta["description"] || ""
            {:ok, name, description, String.trim(body)}

          _ ->
            :error
        end

      _ ->
        # No frontmatter — use filename as name, entire content as template
        name = Path.basename(path, ".md")
        {:ok, name, "Custom command", String.trim(content)}
    end
  end

  defp persist_command(name, description, template) do
    dir = Path.expand(commands_dir())
    File.mkdir_p!(dir)

    content = """
    ---
    name: #{name}
    description: #{description}
    ---

    #{template}
    """

    path = Path.join(dir, "#{name}.md")
    File.write!(path, content)
    Logger.debug("[Commands] Persisted command to #{path}")
  rescue
    e ->
      Logger.warning("[Commands] Failed to persist command #{name}: #{Exception.message(e)}")
  end
end
