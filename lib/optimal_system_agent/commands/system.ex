defmodule OptimalSystemAgent.Commands.System do
  @moduledoc """
  System-level commands: reload, doctor, setup, reset, logs, completion, docs,
  update, create-command, exit, clear, login, logout, export, tasks, config,
  verbose, think, plan, compact, usage, workflow, prime, security, memory,
  utility, and their formatting/generation helpers.
  """

  require Logger

  # ── Config Commands ─────────────────────────────────────────────

  @doc "Handle the `/verbose` command."
  def cmd_verbose(_arg, session_id) do
    current = OptimalSystemAgent.Commands.get_setting(session_id, :verbose, false)
    new_value = !current
    OptimalSystemAgent.Commands.put_setting(session_id, :verbose, new_value)
    {:command, "Verbose mode: #{if new_value, do: "on", else: "off"}"}
  end

  @doc "Handle the `/plan` command."
  def cmd_plan(_arg, session_id) do
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

  @doc "Handle the `/think` command."
  def cmd_think(arg, session_id) do
    level = String.trim(arg) |> String.downcase()

    case level do
      "" ->
        current = OptimalSystemAgent.Commands.get_setting(session_id, :think_level, "normal")
        {:command, "Current reasoning depth: #{current}\n\nUsage: /think fast|normal|deep"}

      l when l in ["fast", "normal", "deep"] ->
        OptimalSystemAgent.Commands.put_setting(session_id, :think_level, l)

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

  @doc "Handle the `/config` command."
  def cmd_config(_arg, session_id) do
    verbose = OptimalSystemAgent.Commands.get_setting(session_id, :verbose, false)
    think = OptimalSystemAgent.Commands.get_setting(session_id, :think_level, "normal")
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

  # ── Context Commands ────────────────────────────────────────────

  @doc "Handle the `/compact` command."
  def cmd_compact(_arg, _session_id) do
    stats = OptimalSystemAgent.Agent.Compactor.stats()

    output =
      """
      Context Compactor:
        compactions:     #{stats[:compaction_count] || 0}
        tokens saved:    #{stats[:tokens_saved] || 0}
        last compacted:  #{OptimalSystemAgent.Commands.Info.format_timestamp(stats[:last_compacted_at])}
        pipeline steps:  #{OptimalSystemAgent.Commands.Info.format_pipeline_steps(stats[:pipeline_steps_used])}
      """
      |> String.trim()

    {:command, output}
  end

  @doc "Handle the `/usage` command."
  def cmd_usage(_arg, session_id) do
    compactor_stats = OptimalSystemAgent.Agent.Compactor.stats()
    memory_stats = OptimalSystemAgent.Agent.Memory.memory_stats()
    max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)

    context_line =
      try do
        case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
          [{pid, _}] ->
            state = :sys.get_state(pid)
            estimated = OptimalSystemAgent.Agent.Compactor.estimate_tokens(state.messages)
            util = if max_tokens > 0, do: Float.round(estimated / max_tokens * 100, 1), else: 0.0
            bar = context_utilization_bar(util)
            "  context now:   #{bar} #{format_number(estimated)}/#{format_number(max_tokens)} (#{util}%)"

          _ ->
            nil
        end
      rescue
        _ -> nil
      end

    lines = [
      "Token Usage:",
      "  max context:     #{format_number(max_tokens)} tokens",
      "  tokens saved:    #{format_number(compactor_stats[:tokens_saved] || 0)} (via compaction)",
      "  compactions:     #{compactor_stats[:compaction_count] || 0}",
      "  sessions stored: #{memory_stats[:session_count] || 0}",
      "  memory on disk:  #{format_bytes(memory_stats[:long_term_size] || 0)}"
    ]

    lines =
      if context_line,
        do: [Enum.at(lines, 0)] ++ [context_line] ++ Enum.drop(lines, 1),
        else: lines

    {:command, Enum.join(lines, "\n")}
  end

  # ── System Commands ─────────────────────────────────────────────

  @doc "Handle the `/reload` command."
  def cmd_reload(_arg, _session_id) do
    OptimalSystemAgent.Soul.reload()
    OptimalSystemAgent.PromptLoader.load()
    {:command, "Soul + prompt files reloaded from disk."}
  end

  @doc "Handle the `/doctor` command."
  def cmd_doctor(_arg, _session_id) do
    checks = [
      check_soul(),
      check_providers(),
      check_ollama(),
      check_tools(),
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

  @doc "Handle the `/setup` command."
  def cmd_setup(_arg, _session_id) do
    OptimalSystemAgent.Onboarding.Channels.run()
    {:command, "Channel setup complete."}
  end

  @doc "Handle the `/reset` command."
  def cmd_reset(arg, _session_id) do
    osa_dir = Path.expand("~/.osa")
    trimmed = String.trim(arg)

    case trimmed do
      "--hard" ->
        paths = ["sessions", "data", "commands", "osa.db", "auth.json"]

        deleted =
          Enum.filter(paths, fn p ->
            full = Path.join(osa_dir, p)

            case File.rm_rf(full) do
              {:ok, _} -> true
              _ -> false
            end
          end)

        {:command, "Hard reset complete. Cleared: #{Enum.join(deleted, ", ")}"}

      "--config" ->
        File.rm(Path.join(osa_dir, "config.json"))
        {:command, "Config reset. Run /setup to reconfigure."}

      "--sessions" ->
        File.rm_rf(Path.join(osa_dir, "sessions"))
        File.mkdir_p(Path.join(osa_dir, "sessions"))
        {:command, "All sessions cleared."}

      "--auth" ->
        File.rm(Path.join(osa_dir, "auth.json"))
        {:command, "Auth tokens cleared."}

      "" ->
        {:command,
         """
         Usage: /reset <scope>
           --hard       Clear sessions, data, commands, auth (keeps config)
           --config     Reset provider configuration
           --sessions   Clear conversation history
           --auth       Clear stored auth tokens
         """}

      _ ->
        {:command, "Unknown reset scope: #{trimmed}. Use /reset for usage."}
    end
  end

  @doc "Handle the `/logs` command."
  def cmd_logs(arg, _session_id) do
    trimmed = String.trim(arg)

    lines =
      case trimmed do
        "" -> 20
        n -> String.to_integer(n)
      end

    log_file = Application.get_env(:optimal_system_agent, :log_file, "log/dev.log")

    case File.read(log_file) do
      {:ok, content} ->
        tail = content |> String.split("\n") |> Enum.take(-lines) |> Enum.join("\n")
        {:command, "Last #{lines} log lines:\n\n#{tail}"}

      {:error, _} ->
        {:command, "No log file found at #{log_file}. Check Logger configuration."}
    end
  rescue
    _ -> {:command, "Invalid line count. Usage: /logs [number]"}
  end

  @doc "Handle the `/completion` command."
  def cmd_completion(arg, _session_id) do
    shell = String.trim(arg)
    commands = OptimalSystemAgent.Commands.list_commands() |> Enum.map(fn {name, _desc, _cat} -> name end)

    case shell do
      "bash" ->
        script = generate_bash_completion(commands)
        {:command, "# Add to ~/.bashrc:\n#{script}"}

      "zsh" ->
        script = generate_zsh_completion(commands)
        {:command, "# Add to ~/.zshrc:\n#{script}"}

      "fish" ->
        script = generate_fish_completion(commands)
        {:command, "# Save to ~/.config/fish/completions/osa.fish:\n#{script}"}

      "" ->
        {:command, "Usage: /completion <shell>\n  Supported: bash, zsh, fish"}

      _ ->
        {:command, "Unsupported shell: #{shell}. Use bash, zsh, or fish."}
    end
  end

  @doc "Handle the `/docs` command."
  def cmd_docs(arg, _session_id) do
    topic = String.trim(arg) |> String.downcase()

    docs = %{
      "" => """
      OSA Documentation — Available Topics:

        /docs agents    — Agent roster, tiers, and dispatch
        /docs swarms    — Multi-agent swarm patterns
        /docs memory    — Episodic memory system
        /docs security  — Security scanning and hardening
        /docs commands  — Command system and custom commands
        /docs config    — Configuration and providers
        /docs channels  — Channel integrations
        /docs api       — HTTP API reference

      Usage: /docs <topic>
      """,
      "agents" => """
      ## Agent System

      OSA uses a 3-tier agent dispatch system:
      - **Elite** (Opus): Complex orchestration, architecture
      - **Specialist** (Sonnet): Domain-specific tasks
      - **Utility** (Haiku): Quick lookups, formatting

      Commands:
        /agents        — List all 22+ agents with roles
        /agents <name> — Show agent details
        /tiers         — Show tier → model mapping
        /tier <t> <m>  — Override a tier's model

      Agents are auto-dispatched by keyword matching:
        bug → debugger, test → test-automator, .go → backend-go
      """,
      "config" => """
      ## Configuration

      Config files:
        ~/.osa/config.json  — Provider, API keys, machines
        ~/.osa/.env         — Environment overrides
        .env (project root) — Project-specific overrides

      Provider priority: OSA_DEFAULT_PROVIDER > API key detection > ollama
      18 providers supported: ollama, anthropic, openai, groq, ...

      Commands:
        /config  — Show runtime config
        /model   — Show/switch provider
        /setup   — Run configuration wizard
        /reset   — Reset config/state
      """,
      "api" => """
      ## HTTP API Reference

      Base: http://localhost:8089/api/v1

      Auth:
        POST /auth/login    — Get JWT token
        POST /auth/logout   — Invalidate session
        POST /auth/refresh  — Refresh expired token

      Core:
        POST /orchestrate        — Process message
        GET  /stream/:session_id — SSE event stream
      Tools & Commands:
        GET  /tools              — List tools
        GET  /commands           — List commands
        POST /commands/execute   — Execute command

      Orchestration:
        POST /orchestrate/complex     — Multi-agent task
        GET  /orchestrate/:id/progress — Progress
      """
    }

    case Map.get(docs, topic) do
      nil -> {:command, "Unknown topic: #{topic}. Run /docs for available topics."}
      content -> {:command, content}
    end
  end

  @doc "Handle the `/update` command."
  def cmd_update(_arg, _session_id) do
    current = Application.spec(:optimal_system_agent, :vsn) |> to_string()

    {:command,
     """
     OSA v#{current}

     Update methods:
       Mix: mix deps.get && mix compile
       Binary: Download latest from releases
       Homebrew: brew upgrade osa (when available)

     Check for updates: https://github.com/miosa/osa/releases
     """}
  end

  @doc "Handle the `/create-command` command."
  def cmd_create(arg, _session_id) do
    result =
      case parse_create_args(arg) do
        {:ok, name, description, template} ->
          case OptimalSystemAgent.Commands.register(name, description, template) do
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

  @doc "Handle the `/exit` and `/quit` command."
  def cmd_exit(_arg, _session_id) do
    {:action, :exit, ""}
  end

  @doc "Handle the `/clear` command."
  def cmd_clear(_arg, _session_id) do
    {:action, :clear, ""}
  end

  # ── Auth Commands ───────────────────────────────────────────────

  @doc "Handle the `/login` command."
  def cmd_login(arg, session_id) do
    user_id = if arg == "", do: "cli_#{session_id}", else: String.trim(arg)
    token = OptimalSystemAgent.Channels.HTTP.Auth.generate_token(%{"user_id" => user_id})
    refresh = OptimalSystemAgent.Channels.HTTP.Auth.generate_refresh_token(%{"user_id" => user_id})

    auth_path = Path.expand("~/.osa/auth.json")
    File.mkdir_p!(Path.dirname(auth_path))
    auth_data = Jason.encode!(%{token: token, refresh_token: refresh, user_id: user_id})
    File.write(auth_path, auth_data)

    {:command,
     """
     Authenticated as #{user_id}
       Token expires in 15 minutes
       Refresh token valid for 7 days
       Saved to ~/.osa/auth.json

     TUI users: token is auto-loaded. CLI users: export OSA_TOKEN=#{token}
     """}
  end

  @doc "Handle the `/logout` command."
  def cmd_logout(_arg, _session_id) do
    auth_path = Path.expand("~/.osa/auth.json")
    File.rm(auth_path)
    {:command, "Logged out. Token cleared from ~/.osa/auth.json"}
  end

  # ── Export Command ──────────────────────────────────────────────

  @doc "Handle the `/export` command."
  def cmd_export(arg, session_id) do
    trimmed = String.trim(arg)

    filename =
      if trimmed == "" do
        timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
        "osa_session_#{timestamp}.md"
      else
        trimmed
      end

    try do
      messages = OptimalSystemAgent.Agent.Memory.load_session(session_id)

      if messages == [] or is_nil(messages) do
        {:command, "No messages in current session to export."}
      else
        content =
          [
            "# OSA Session Export",
            "Session: #{session_id}",
            "Exported: #{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")}",
            "Messages: #{length(messages)}",
            "",
            "---",
            ""
            | Enum.map(messages, fn msg ->
                role = msg[:role] || msg["role"] || "unknown"
                text = msg[:content] || msg["content"] || ""
                "## #{String.capitalize(to_string(role))}\n\n#{text}\n"
              end)
          ]
          |> Enum.join("\n")

        path = Path.expand(filename)
        File.write!(path, content)

        {:command, "Session exported to: #{path}\n  Messages: #{length(messages)}"}
      end
    rescue
      e -> {:command, "Export failed: #{Exception.message(e)}"}
    end
  end

  # ── Task Tracker ────────────────────────────────────────────────

  @doc "Handle the `/tasks` command."
  def cmd_tasks(arg, session_id) do
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
        title = trimmed |> String.replace_prefix("add ", "") |> String.trim() |> String.trim("\"")

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

  # ── Workflow Expansion Commands ─────────────────────────────────

  @doc "Handle workflow commands: /commit, /build, /test, /lint, /verify, /create-pr, /fix, /explain."
  def cmd_workflow(arg, _session_id) do
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

  @doc "Handle context priming commands: /prime, /prime-backend, /prime-webdev, etc."
  def cmd_prime(arg, _session_id) do
    cmd_name = Process.get(:osa_current_cmd, "prime")

    case OptimalSystemAgent.PromptLoader.get_command("context", cmd_name) do
      nil ->
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

  @doc "Handle security commands: /security-scan, /secret-scan, /harden."
  def cmd_security(arg, _session_id) do
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

  @doc "Handle memory commands: /mem-search, /mem-save, /mem-recall, etc."
  def cmd_memory_cmd(arg, _session_id) do
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

  @doc "Handle the `/analytics` command — show real SICA + budget + session metrics."
  def cmd_analytics(_arg, _session_id) do
    try do
      metrics = OptimalSystemAgent.Agent.Learning.metrics()
      sessions = Registry.count(OptimalSystemAgent.Channels.SessionRegistry)

      budget_line =
        try do
          {:ok, status} = OptimalSystemAgent.Agent.Budget.get_status()
          "  Tokens used:          #{status.tokens_used} / #{status.tokens_limit}"
        rescue
          _ -> "  Budget tracker not available"
        end

      compactor_line =
        try do
          stats = OptimalSystemAgent.Agent.Compactor.stats()
          "  Compactions:          #{stats.total_compactions} (#{stats.tokens_saved} tokens saved)"
        rescue
          _ -> "  Compactor not available"
        end

      output = """
      Analytics

      Sessions:
        Active sessions:      #{sessions}

      Learning (SICA):
        Total interactions:   #{metrics.total_interactions}
        Patterns captured:    #{metrics.patterns_captured}
        Skills generated:     #{metrics.skills_generated}
        Errors recovered:     #{metrics.errors_recovered}

      Budget:
      #{budget_line}

      Context:
      #{compactor_line}
      """

      {:command, String.trim(output)}
    rescue
      _ -> {:command, "Analytics not available — agent subsystems may not be fully initialized."}
    end
  end

  @doc "Handle utility commands: /debug, /search, /review, /pr-review, /refactor, /banner, /init."
  def cmd_utility(arg, _session_id) do
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

  # ── Doctor Check helpers ────────────────────────────────────────

  @doc false
  def check_soul do
    identity = OptimalSystemAgent.Soul.identity()
    soul = OptimalSystemAgent.Soul.soul()

    cond do
      identity && soul -> {:ok, "Soul", "identity + soul loaded"}
      identity -> {:warn, "Soul", "identity loaded, soul using defaults"}
      soul -> {:warn, "Soul", "soul loaded, identity using defaults"}
      true -> {:warn, "Soul", "using defaults (no ~/.osa/IDENTITY.md or SOUL.md)"}
    end
  end

  @doc false
  def check_providers do
    providers = OptimalSystemAgent.Providers.Registry.list_providers()

    if length(providers) > 0 do
      {:ok, "Providers", "#{length(providers)} loaded"}
    else
      {:fail, "Providers", "no LLM providers available"}
    end
  end

  @doc false
  def check_ollama do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    if provider == :ollama do
      url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

      case Req.get("#{url}/api/tags", receive_timeout: 3_000) do
        {:ok, %{status: 200, body: %{"models" => models}}} ->
          {:ok, "Ollama", "#{length(models)} models at #{url}"}

        {:ok, %{status: status}} ->
          {:warn, "Ollama", "responded with status #{status}"}

        {:error, _} ->
          {:fail, "Ollama", "unreachable at #{url}"}
      end
    else
      {:ok, "Ollama", "skipped (provider: #{provider})"}
    end
  rescue
    _ -> {:fail, "Ollama", "health check failed"}
  end

  @doc false
  def check_tools do
    skills = OptimalSystemAgent.Tools.Registry.list_tools_direct()

    cond do
      length(skills) >= 5 -> {:ok, "Tools", "#{length(skills)} available"}
      length(skills) > 0 -> {:warn, "Tools", "#{length(skills)} available (low)"}
      true -> {:fail, "Tools", "no tools loaded"}
    end
  end

  @doc false
  def check_memory do
    stats = OptimalSystemAgent.Agent.Memory.memory_stats()
    count = stats[:entry_count] || stats[:session_count] || 0

    if count >= 0 do
      {:ok, "Memory",
       "#{stats[:session_count] || 0} sessions, #{stats[:entry_count] || 0} entries"}
    else
      {:warn, "Memory", "no data yet"}
    end
  end

  @doc false
  def check_cortex do
    stats = OptimalSystemAgent.Agent.Cortex.synthesis_stats()

    if stats[:has_bulletin] do
      {:ok, "Cortex", "bulletin active, #{stats[:active_topic_count] || 0} topics"}
    else
      {:warn, "Cortex", "no bulletin yet (will generate on first cycle)"}
    end
  end

  @doc false
  def check_scheduler do
    case Process.whereis(OptimalSystemAgent.Agent.Scheduler) do
      nil -> {:fail, "Scheduler", "not running"}
      pid when is_pid(pid) -> {:ok, "Scheduler", "running (pid #{inspect(pid)})"}
    end
  end

  @doc false
  def check_http do
    port = Application.get_env(:optimal_system_agent, :http_port, 8089)

    case :gen_tcp.connect(~c"127.0.0.1", port, [], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:ok, "HTTP", "listening on port #{port}"}

      {:error, _} ->
        {:fail, "HTTP", "port #{port} not responding"}
    end
  end

  # ── Completion Code Generation ──────────────────────────────────

  @doc false
  def generate_bash_completion(commands) do
    cmds = Enum.join(commands, " ")

    """
    _osa_completions() {
      local cur="${COMP_WORDS[COMP_CWORD]}"
      if [[ "$cur" == /* ]]; then
        COMPREPLY=($(compgen -W "#{cmds}" -- "${cur#/}"))
        COMPREPLY=("${COMPREPLY[@]/#//}")
      fi
    }
    complete -F _osa_completions osa
    """
  end

  @doc false
  def generate_zsh_completion(commands) do
    items = Enum.map(commands, fn c -> "'#{c}'" end) |> Enum.join(" ")

    """
    _osa() {
      local -a commands=(#{items})
      _describe 'command' commands
    }
    compdef _osa osa
    """
  end

  @doc false
  def generate_fish_completion(commands) do
    Enum.map_join(commands, "\n", fn c ->
      "complete -c osa -a '/#{c}' -d '#{c}'"
    end)
  end

  # ── Custom command parse helpers ────────────────────────────────

  @doc false
  def parse_create_args(""), do: :help

  def parse_create_args(arg) do
    case String.split(arg, "|", parts: 3) do
      [name, desc, template] ->
        {:ok, String.trim(name), String.trim(desc), String.trim(template)}

      [name, template] ->
        {:ok, String.trim(name), "Custom command", String.trim(template)}

      _ ->
        :help
    end
  end

  # ── Formatting Helpers ──────────────────────────────────────────

  @doc "Format an integer with thousands separators."
  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(n), do: "#{n}"

  @doc "Format a byte count into a human-readable string."
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  def format_bytes(bytes) when is_integer(bytes), do: "#{bytes} bytes"
  def format_bytes(_), do: "0 bytes"

  @doc "Render a coloured utilization bar for context window usage."
  def context_utilization_bar(util) do
    filled = round(util / 5) |> min(20) |> max(0)
    empty = 20 - filled

    cond do
      util >= 90.0 ->
        "#{IO.ANSI.red()}[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}]#{IO.ANSI.reset()}"

      util >= 70.0 ->
        "#{IO.ANSI.yellow()}[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}]#{IO.ANSI.reset()}"

      true ->
        "#{IO.ANSI.green()}[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}]#{IO.ANSI.reset()}"
    end
  end

  # ── Shell Command ────────────────────────────────────────────────

  @doc "Handle the `shell` command (used internally by TUI `!<cmd>` mode)."
  def cmd_shell("", _session_id) do
    {:command, "Usage: !<command>  (e.g. !ls -la, !npm install)\nRuns in ~/.osa/workspace/"}
  end

  def cmd_shell(arg, _session_id) do
    alias OptimalSystemAgent.Tools.Builtins.ShellExecute

    case ShellExecute.execute(%{"command" => arg}) do
      {:ok, output} -> {:command, output}
      {:error, reason} -> {:command, "Error: #{reason}"}
    end
  end
end
