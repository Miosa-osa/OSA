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

  @doc "List all available commands with descriptions and categories."
  @spec list_commands() :: list({String.t(), String.t(), String.t()})
  def list_commands do
    builtins = Enum.map(builtin_commands(), fn {name, desc, _} -> {name, desc, category_for(name)} end)

    customs =
      try do
        :ets.tab2list(@ets_table)
        |> Enum.map(fn {name, _template, desc} -> {name, desc, "custom"} end)
      rescue
        ArgumentError -> []
      end

    builtins ++ customs
  end

  @doc false
  defp category_for(name) do
    case name do
      n when n in ~w(help status skills memory soul model models provider commands) -> "info"
      n when n in ~w(new sessions resume history) -> "session"
      n when n in ~w(channels whatsapp) -> "channels"
      n when n in ~w(compact usage) -> "context"
      "cortex" -> "intelligence"
      n when n in ~w(verbose think plan config) -> "config"
      n when n in ~w(agents tiers tier swarms swarm hooks learning) -> "agents"
      n when n in ~w(budget thinking export machines providers) -> "info"
      n when n in ~w(reload doctor setup create-command) -> "system"
      n when n in ~w(commit build test lint verify create-pr fix explain) -> "workflow"
      n when n in ~w(prime prime-backend prime-webdev prime-svelte prime-security prime-devops prime-testing prime-osa prime-miosa) -> "priming"
      n when n in ~w(security-scan secret-scan harden) -> "security"
      n when n in ~w(mem-search mem-save mem-recall mem-list mem-stats mem-delete mem-context mem-export) -> "memory"
      n when n in ~w(schedule cron triggers heartbeat) -> "scheduler"
      "tasks" -> "tasks"
      n when n in ~w(analytics debug search review pr-review refactor banner init) -> "analytics"
      n when n in ~w(login logout) -> "auth"
      n when n in ~w(reset logs completion docs update) -> "system"
      n when n in ~w(exit quit clear) -> "system"
      _ -> "system"
    end
  end

  @doc "Register a custom command at runtime."
  @spec register(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def register(name, description, template) do
    GenServer.call(__MODULE__, {:register, name, description, template})
  end

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
    # Create ETS table for command lookup (guard against re-creation on restart)
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
    end

    # Create ETS table for per-session runtime settings (guard against re-creation on restart)
    if :ets.whereis(@settings_table) == :undefined do
      :ets.new(@settings_table, [:set, :public, :named_table, read_concurrency: true])
    end

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
        try do
          case :ets.lookup(@ets_table, cmd) do
            [{^cmd, template, _desc}] -> {:custom, template}
            [] -> :not_found
          end
        rescue
          ArgumentError -> :not_found
        end
    end
  end

  # ── Built-in Commands ──────────────────────────────────────────

  defp builtin_commands do
    alias OptimalSystemAgent.Commands.{Info, Session, Channels, Agents, SchedulerCmd, System}
    alias OptimalSystemAgent.Commands.{Config, Auth, Data}
    alias OptimalSystemAgent.Commands.Model

    [
      # ── Info ──
      {"help", "Show available commands", &Info.cmd_help/2},
      {"status", "System status", &Info.cmd_status/2},
      {"skills", "List available skills", &Info.cmd_skills/2},
      {"memory", "Memory statistics", &Info.cmd_memory/2},
      {"soul", "Show personality config", &Info.cmd_soul/2},
      {"model", "Show/switch LLM provider", &Model.cmd_model/2},
      {"models", "List installed Ollama models", &Model.cmd_models_shortcut/2},
      {"provider", "Alias for /model", &Model.cmd_model/2},
      {"commands", "List all commands", &Info.cmd_help/2},

      # ── Session Management ──
      {"new", "Start a fresh session", &Session.cmd_new/2},
      {"sessions", "List stored sessions", &Session.cmd_sessions/2},
      {"resume", "Resume a previous session", &Session.cmd_resume/2},
      {"history", "Browse conversation history", &Session.cmd_history/2},

      # ── Channels ──
      {"channels", "Manage channel adapters", &Channels.cmd_channels/2},
      {"whatsapp", "WhatsApp Web shortcut", &Channels.cmd_whatsapp/2},

      # ── Context & Performance ──
      {"compact", "Context compaction stats", &Config.cmd_compact/2},
      {"usage", "Token usage breakdown", &Config.cmd_usage/2},

      # ── Intelligence ──
      {"cortex", "Cortex bulletin & topics", &Info.cmd_cortex/2},

      # ── Configuration ──
      {"verbose", "Toggle verbose output", &Config.cmd_verbose/2},
      {"think", "Set reasoning depth", &Config.cmd_think/2},
      {"plan", "Toggle autonomous plan mode", &Config.cmd_plan/2},
      {"config", "Show runtime configuration", &Config.cmd_config/2},

      # ── Agents ──
      {"agents", "List all agents in the roster", &Agents.cmd_agents/2},
      {"tiers", "Show model tier configuration", &Agents.cmd_tiers/2},
      {"tier", "Set a tier model override", &Agents.cmd_tier_set/2},
      {"swarms", "List swarm presets", &Agents.cmd_swarms/2},
      {"swarm", "Launch a swarm: /swarm <preset> <task>", &Agents.cmd_swarm/2},
      {"hooks", "Show hook pipeline status", &Agents.cmd_hooks/2},
      {"learning", "Learning engine metrics", &Agents.cmd_learning/2},

      # ── Budget / thinking / machines ──
      {"budget", "Token and cost budget status", &Agents.cmd_budget/2},
      {"thinking", "Toggle extended thinking mode", &Agents.cmd_thinking/2},
      {"export", "Export session to file", &Data.cmd_export/2},
      {"machines", "List connected machines", &Agents.cmd_machines/2},
      {"providers", "List available LLM providers", &Model.cmd_providers/2},

      # ── System ──
      {"reload", "Reload soul/skill files", &System.cmd_reload/2},
      {"doctor", "System diagnostics", &System.cmd_doctor/2},
      {"setup", "Run channel setup wizard", &System.cmd_setup/2},
      {"create-command", "Create a new command", &System.cmd_create/2},

      # ── Workflow ──
      {"commit", "Generate a proper git commit", &System.cmd_workflow/2},
      {"build", "Build project with auto-detection", &System.cmd_workflow/2},
      {"test", "Run tests with auto-detection", &System.cmd_workflow/2},
      {"lint", "Run linting with auto-fix", &System.cmd_workflow/2},
      {"verify", "Run completion checklist", &System.cmd_workflow/2},
      {"create-pr", "Create a pull request", &System.cmd_workflow/2},
      {"fix", "Apply fixes from review", &System.cmd_workflow/2},
      {"explain", "Explain code or concepts", &System.cmd_workflow/2},

      # ── Context Priming ──
      {"prime", "Show loaded context", &System.cmd_prime/2},
      {"prime-backend", "Load Go backend context", &System.cmd_prime/2},
      {"prime-webdev", "Load React/Next.js context", &System.cmd_prime/2},
      {"prime-svelte", "Load Svelte/SvelteKit context", &System.cmd_prime/2},
      {"prime-security", "Load security audit context", &System.cmd_prime/2},
      {"prime-devops", "Load DevOps/infra context", &System.cmd_prime/2},
      {"prime-testing", "Load testing/QA context", &System.cmd_prime/2},
      {"prime-osa", "Load OSA terminal context", &System.cmd_prime/2},
      {"prime-miosa", "Load MIOSA platform context", &System.cmd_prime/2},

      # ── Security ──
      {"security-scan", "Run security scan", &System.cmd_security/2},
      {"secret-scan", "Detect hardcoded secrets", &System.cmd_security/2},
      {"harden", "Security hardening recommendations", &System.cmd_security/2},

      # ── Memory ──
      {"mem-search", "Search episodic memory", &System.cmd_memory_cmd/2},
      {"mem-save", "Save to persistent memory", &System.cmd_memory_cmd/2},
      {"mem-recall", "Recall memory by topic", &System.cmd_memory_cmd/2},
      {"mem-list", "List memory entries", &System.cmd_memory_cmd/2},
      {"mem-stats", "Memory statistics", &System.cmd_memory_cmd/2},
      {"mem-delete", "Delete memory entry", &System.cmd_memory_cmd/2},
      {"mem-context", "Save conversation context", &System.cmd_memory_cmd/2},
      {"mem-export", "Export memory to file", &System.cmd_memory_cmd/2},

      # ── Scheduler ──
      {"schedule", "Scheduler overview", &SchedulerCmd.cmd_schedule/2},
      {"cron", "Manage cron jobs", &SchedulerCmd.cmd_cron/2},
      {"triggers", "Manage event triggers", &SchedulerCmd.cmd_triggers/2},
      {"heartbeat", "Heartbeat tasks", &SchedulerCmd.cmd_heartbeat/2},

      # ── Task Tracker ──
      {"tasks", "Show/manage tracked tasks", &Data.cmd_tasks/2},

      # ── Analytics ──
      {"analytics", "Usage analytics and metrics", &System.cmd_utility/2},
      {"debug", "Start systematic debugging", &System.cmd_utility/2},
      {"search", "Search codebase and docs", &System.cmd_utility/2},
      {"review", "Code review on recent changes", &System.cmd_utility/2},
      {"pr-review", "Review a pull request", &System.cmd_utility/2},
      {"refactor", "Safe code refactoring", &System.cmd_utility/2},
      {"banner", "Show OSA banner", &System.cmd_utility/2},
      {"init", "Initialize project", &System.cmd_utility/2},

      # ── Auth ──
      {"login", "Authenticate with the backend", &Auth.cmd_login/2},
      {"logout", "End session and clear token", &Auth.cmd_logout/2},

      # ── System Management ──
      {"reset", "Reset local config/state", &System.cmd_reset/2},
      {"logs", "Stream backend logs", &System.cmd_logs/2},
      {"completion", "Generate shell completion", &System.cmd_completion/2},
      {"docs", "Built-in documentation", &System.cmd_docs/2},
      {"update", "Check for updates", &System.cmd_update/2},

      # ── Shell (TUI !<cmd> mode) ──
      {"shell", "Execute a shell command in ~/.osa/workspace", &System.cmd_shell/2},

      # ── Exit ──
      {"exit", "Exit the CLI", &System.cmd_exit/2},
      {"quit", "Exit the CLI", &System.cmd_exit/2},
      {"clear", "Clear the screen", &System.cmd_clear/2}
    ]
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
