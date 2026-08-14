defmodule OptimalSystemAgent.Channels.CLI.Commands do
  @moduledoc """
  Slash command registry and dispatch for the CLI REPL.

  Commands are registered as `{handler_fn, description}` pairs in a static map.
  Dispatch parses the command name and arguments, routes to the handler, and
  returns the (possibly new) session_id.
  """

  require Logger

  alias OptimalSystemAgent.Agent.{Compactor, ContextDiscovery, Loop, SessionPersistence, Tasks}
  alias OptimalSystemAgent.Budget
  alias OptimalSystemAgent.Channels.CLI.{MessageQueue, Renderer, Session, TaskDisplay}
  alias OptimalSystemAgent.ContextRefs.Parser, as: ContextRefsParser
  alias OptimalSystemAgent.MCP
  alias OptimalSystemAgent.Memory
  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Sandbox.Router, as: SandboxRouter
  alias OptimalSystemAgent.Tools.Builtins.{SkillManager, UseSkill}
  alias OptimalSystemAgent.Tools.Registry, as: ToolsRegistry
  alias OptimalSystemAgent.Providers.Registry, as: ProviderRegistry

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @yellow IO.ANSI.yellow()
  @green IO.ANSI.green()
  @red IO.ANSI.red()

  @commands %{
    "help" => {"Show available commands", :cmd_help},
    "clear" => {"Clear conversation and start fresh session", :cmd_clear},
    "new" => {"Start a new session (alias for /clear)", :cmd_clear},
    "compact" => {"Force context compaction", :cmd_compact},
    "model" => {"Show or switch the current model", :cmd_model},
    "status" => {"Show session status", :cmd_status},
    "cost" => {"Show cost breakdown", :cmd_cost},
    "usage" => {"Show account quota and this session's token usage", :cmd_usage},
    "context" => {"Show context window usage", :cmd_context},
    "memory" => {"Show memory entries", :cmd_memory},
    "tools" => {"List available tools", :cmd_tools},
    "skills" => {"List, run, enable, disable, or create a skill", :cmd_skill},
    "skill" => {"List, run, enable, disable, or create a skill", :cmd_skill},
    "agents" => {"Runtime agent dashboard — live subagent runs and roles", :cmd_agents},
    "bg" => {"List background work — subagent runs and background commands", :cmd_bg},
    "fg" => {"Foreground a running agent/fleet node — switch the active session to it", :cmd_fg},
    "steer" => {"Inject a directive into the running turn (mid-turn steer)", :cmd_steer},
    "sessions" => {"List recent sessions", :cmd_sessions},
    "tasks" => {"Show current tasks", :cmd_tasks},
    "plan" => {"Toggle plan mode", :cmd_plan},
    "doctor" => {"Run health check", :cmd_doctor},
    "export" => {"Export conversation as markdown", :cmd_export},
    "version" => {"Show version and check for updates", :cmd_version},
    "release-notes" => {"Show what's new in this release", :cmd_release_notes},
    "coordinator" => {"Toggle coordinator mode (delegation only)", :cmd_coordinator},
    "effort" => {"Set thinking effort level (low/medium/high/max)", :cmd_effort},
    "fast" => {"Toggle fast mode (low effort)", :cmd_fast},
    "permissions" => {"View and manage permission rules", :cmd_permissions},
    "hooks" => {"View registered hooks", :cmd_hooks},
    "metrics" => {"Show telemetry metrics", :cmd_metrics},
    "login" => {"Sign in to a provider account, or show sign-in status", :cmd_login},
    "logout" => {"Sign out of a provider account", :cmd_logout},
    "setup" => {"Re-run the setup wizard", :cmd_setup},
    "customize" => {"Make OSA yours — identity, skills, schedules, channels", :cmd_customize},
    "channels" => {"Show connected messaging channels", :cmd_channels},
    "resume" => {"Resume a previous session", :cmd_resume},
    "persona" => {"Show or switch persona preset", :cmd_persona},
    "mcp" => {"List MCP servers and connection status", :cmd_mcp},
    "init" => {"Scan the project and write an AGENTS.md guide", :cmd_init},
    "map" => {"Map the workspace — components, submodules, nested repos", :cmd_map},
    "copy" => {"Copy the last assistant reply", :cmd_copy},
    "files" => {"List files currently in context", :cmd_files},
    "rename" => {"Rename the current session", :cmd_rename},
    "tag" => {"Tag the current session for search", :cmd_tag},
    "sandbox" => {"Show or switch the sandbox backend", :cmd_sandbox},
    "add-dir" => {"Allow file access in an additional directory", :cmd_add_dir},
    "trust" => {"Show or accept workspace trust for this directory", :cmd_trust},
    "exit" => {"Exit OSA", :cmd_exit}
  }

  @init_guide "AGENTS.md"

  @doc "List all command names (for autocomplete)."
  def list, do: Map.keys(@commands) |> Enum.sort()

  @doc "List all commands with their descriptions as `{name, description}` tuples."
  def list_with_descriptions do
    @commands
    |> Enum.map(fn {name, {desc, _handler}} -> {name, desc} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Dispatch a slash command. Returns the (possibly new) session_id."
  def dispatch(input, session_id) do
    {cmd_name, args} = parse_command(input)

    case Map.get(@commands, cmd_name) do
      {_desc, handler} ->
        apply(__MODULE__, handler, [args, session_id])

      nil ->
        suggest_similar(cmd_name)
        session_id
    end
  end

  # ── Command Implementations ──────────────────────────────────────────

  def cmd_help(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Available Commands#{@reset}")
    IO.puts("")

    @commands
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.each(fn {name, {desc, _handler}} ->
      padded = String.pad_trailing("/#{name}", 16)
      IO.puts("  #{@cyan}#{padded}#{@reset} #{@dim}#{desc}#{@reset}")
    end)

    # User-defined custom commands from ~/.osa/commands/*.md (Claude-Code-style).
    custom =
      try do
        OptimalSystemAgent.Tools.Registry.CommandLoader.list_with_descriptions()
      rescue
        _ -> []
      end

    if custom != [] do
      IO.puts("")
      IO.puts("  #{@bold}Custom Commands#{@reset} #{@dim}(~/.osa/commands/)#{@reset}")
      IO.puts("")

      Enum.each(custom, fn {name, desc} ->
        padded = String.pad_trailing("/#{name}", 16)
        truncated = String.slice(desc, 0, 55)
        IO.puts("  #{@cyan}#{padded}#{@reset} #{@dim}#{truncated}#{@reset}")
      end)
    end

    IO.puts("")
    session_id
  end

  def cmd_clear(_args, session_id) do
    new_id = Session.start_new_session(session_id)
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    Renderer.print_banner()
    IO.puts("")
    new_id
  end

  def cmd_compact(args, session_id) do
    IO.puts("")
    IO.puts("  #{@dim}Compacting context...#{@reset}")

    # CC parity: `/compact <instructions>` threads user guidance into the
    # summary prompt via the proactive path; bare `/compact` keeps the
    # legacy reactive Loop.compact path.
    case String.trim(args || "") do
      "" ->
        compact_without_instructions(session_id)

      instructions ->
        case Loop.proactive_compact(session_id, instructions) do
          {:ok, stats} ->
            IO.puts(
              "  #{@green}#{@reset} Compacted: #{format_tokens(stats.tokens_before)} -> #{format_tokens(stats.tokens_after)}"
            )

          {:error, :no_session} ->
            IO.puts("  #{@yellow}error: no active session#{@reset}")

          {:error, reason} ->
            IO.puts("  #{@yellow}error: #{inspect(reason)}#{@reset}")
        end
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: compaction failed#{@reset}\n")
      session_id
  end

  # Bare `/compact` — original reactive compaction with before/after stats.
  defp compact_without_instructions(session_id) do
    case Loop.get_state(session_id) do
      {:ok, state} ->
        before_tokens = state[:tokens_used] || state[:estimated_tokens] || 0

        case Loop.compact(session_id) do
          :ok ->
            case Loop.get_state(session_id) do
              {:ok, after_state} ->
                after_tokens = after_state[:tokens_used] || after_state[:estimated_tokens] || 0
                saved = before_tokens - after_tokens
                pct = if before_tokens > 0, do: round(saved / before_tokens * 100), else: 0

                IO.puts(
                  "  #{@green}#{@reset} Compacted: #{format_tokens(before_tokens)} -> #{format_tokens(after_tokens)} (#{pct}% reduction)"
                )

              _ ->
                IO.puts("  #{@green}#{@reset} Compacted successfully")
            end

          {:error, reason} ->
            IO.puts("  #{@yellow}error: #{reason}#{@reset}")
        end

      _ ->
        IO.puts("  #{@yellow}error: no active session#{@reset}")
    end
  end

  # Which credential the current provider is actually using. Without this the
  # only difference between a plan-metered session and a pay-per-token one is
  # invisible until the bill arrives — and the two have opposite failure modes
  # (a window that resets vs a charge that does not).
  #
  # Pure read: `Subscription.status/1` never touches the network, so `/model`
  # cannot hang on, or be failed by, a token refresh.
  defp print_auth_mode(provider) do
    status = OptimalSystemAgent.Auth.Subscription.status(provider)

    cond do
      status.connected? and status.expired? ->
        IO.puts(
          "  #{@dim}Auth:#{@reset}      account sign-in #{@dim}(expired — re-run setup)#{@reset}"
        )

      status.connected? ->
        IO.puts("  #{@dim}Auth:#{@reset}      account sign-in#{plan_and_account(status)}")

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp plan_and_account(status) do
    parts = Enum.reject([status.plan, status.account], &(is_nil(&1) or &1 == ""))
    if parts == [], do: "", else: " #{@dim}(#{Enum.join(parts, ", ")})#{@reset}"
  end

  # For the Claude Code bridge the configured model is an ALIAS; the concrete
  # model is chosen downstream. Show what actually ran, once it is known, so
  # the header cannot claim a model OSA is not using.
  defp print_resolved_model(:claude_cli, alias_name) do
    case OptimalSystemAgent.Providers.ClaudeCli.last_resolved_model() do
      resolved when is_binary(resolved) and resolved != alias_name ->
        IO.puts(
          "  #{@dim}Running:#{@reset}   #{resolved} #{@dim}(resolved by Claude Code)#{@reset}"
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp print_resolved_model(_provider, _model), do: :ok

  def cmd_model(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "" ->
        provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
        model = get_model_name(provider)
        ctx = ProviderRegistry.effective_context_window(model, provider)

        IO.puts("  #{@bold}Current Model#{@reset}")
        IO.puts("  #{@dim}Provider:#{@reset}  #{provider}")
        IO.puts("  #{@dim}Model:#{@reset}     #{model}")
        IO.puts("  #{@dim}Context:#{@reset}   #{format_context_window(ctx)} tokens")
        print_auth_mode(provider)
        print_resolved_model(provider, model)

      model_arg ->
        IO.puts("  #{@dim}Switching model...#{@reset}")

        case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
          [{pid, _}] ->
            {provider, model_name} =
              case parse_model_arg(model_arg) do
                {:explicit, prov, m} ->
                  {prov, m}

                {:model_only, m} ->
                  provider =
                    ProviderRegistry.provider_for_model(m) ||
                      Application.get_env(:optimal_system_agent, :default_provider, :ollama)

                  {provider, m}
              end

            case GenServer.call(pid, {:swap_provider, provider, model_name}) do
              {:ok, info} ->
                ctx = ProviderRegistry.effective_context_window(info.model, info.provider)

                IO.puts(
                  "  #{@green}#{@reset} Switched to #{info.model} #{@dim}(#{info.provider}, #{format_context_window(ctx)} ctx)#{@reset}"
                )

              {:error, reason} ->
                IO.puts("  #{@yellow}error: #{reason}#{@reset}")

              :ok ->
                IO.puts("  #{@green}#{@reset} Switched to #{model_name}")
            end

          _ ->
            IO.puts("  #{@yellow}error: session not found#{@reset}")
        end
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: model switch failed#{@reset}\n")
      session_id
  end

  def cmd_status(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Session Status#{@reset}")

    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
    # Identity.model/0 rather than the old Format.get_model_name/1: that read
    # `:ollama_model` while /health (and therefore the status bar) reads
    # `:default_model`. Both are written at boot, but a mid-session /switch
    # writes them separately, so `/status` could report a different model than
    # the bar. One resolver, no drift.
    model = OptimalSystemAgent.Runtime.Identity.model()
    {_src, model_source} = OptimalSystemAgent.Runtime.Identity.model_source()
    tool_count = length(ToolsRegistry.list_tools_direct())
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)

    IO.puts("  #{@dim}Session:#{@reset}   #{session_id}")
    IO.puts("  #{@dim}Uptime:#{@reset}    #{Renderer.format_elapsed(uptime_ms)}")
    IO.puts("  #{@dim}Provider:#{@reset}  #{provider}")
    IO.puts("  #{@dim}Model:#{@reset}     #{model} #{@dim}(from #{model_source})#{@reset}")
    IO.puts("  #{@dim}Tools:#{@reset}     #{tool_count} loaded")

    case Loop.get_state(session_id) do
      {:ok, state} ->
        iter = state[:iteration] || state[:iteration_count] || 0
        tokens = state[:tokens_used] || state[:estimated_tokens] || 0
        max_tokens = ProviderRegistry.effective_context_window(get_model_name(provider), provider)
        pct = if max_tokens > 0, do: round(tokens / max_tokens * 100), else: 0

        IO.puts("  #{@dim}Iteration:#{@reset} #{iter}")

        IO.puts(
          "  #{@dim}Context:#{@reset}   #{pct}% (#{format_tokens(tokens)} / #{format_context_window(max_tokens)})"
        )

      _ ->
        :ok
    end

    try do
      budget = unwrap_budget(Budget.get_status())
      cost = budget[:monthly_spent] || budget[:total_cost_usd] || 0

      IO.puts(
        "  #{@dim}Cost:#{@reset}      $#{fmt_usd(cost)} " <>
          "#{@dim}(#{cost_period_label(budget)}, OSA-measured)#{@reset}"
      )
    rescue
      _ -> :ok
    end

    skill_count = length(ToolsRegistry.list_skills())
    IO.puts("  #{@dim}Skills:#{@reset}    #{skill_count} loaded")

    try do
      mem_stats = Memory.stats()
      mem_count = mem_stats[:total] || mem_stats[:count] || 0
      IO.puts("  #{@dim}Memory:#{@reset}    #{mem_count} entries")
    rescue
      _ -> :ok
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: status unavailable#{@reset}\n")
      session_id
  end

  def cmd_cost(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Cost Summary#{@reset}")

    try do
      # `Budget.get_status/0` returns `{:ok, map}`. Reading it as a bare map
      # raised inside the `try`, so this block printed "No cost data
      # available" unconditionally — a working ledger rendered as an empty one.
      budget = unwrap_budget(Budget.get_status())
      total = budget[:monthly_spent] || budget[:total_cost_usd] || 0
      tokens = budget[:monthly_tokens] || 0
      # `ledger_entries` is the size of a list capped at 10 000, so it stopped
      # being a call count at 10 000. `monthly_calls` is the real counter.
      calls = budget[:monthly_calls] || budget[:ledger_entries] || budget[:sessions] || 0

      # The ledger is in-memory only — nothing is loaded at boot and nothing is
      # saved at shutdown — so "this month" is a claim it cannot support. Label
      # the period by what it actually covers.
      period = cost_period_label(budget)

      IO.puts("  #{@dim}├─ Tokens:#{@reset}   #{format_tokens(tokens)} tokens #{period}")
      IO.puts("  #{@dim}├─ Today:#{@reset}    $#{fmt_usd(budget[:daily_spent] || 0)}")
      IO.puts("  #{@dim}├─ Calls:#{@reset}    #{calls}")
      IO.puts("  #{@dim}└─ Total:#{@reset}    $#{fmt_usd(total)} #{@dim}(#{period})#{@reset}")

      IO.puts("")

      IO.puts(
        "  #{@dim}This is OSA's own count of what it ran, priced from a static rate#{@reset}"
      )

      IO.puts(
        "  #{@dim}table. For what your account has left, use#{@reset} #{@cyan}/usage#{@reset}"
      )
    rescue
      _ ->
        IO.puts("  #{@dim}  No cost data available#{@reset}")
    end

    IO.puts("")
    session_id
  end

  defp unwrap_budget({:ok, map}) when is_map(map), do: map
  defp unwrap_budget(map) when is_map(map), do: map
  defp unwrap_budget(_), do: %{}

  defp fmt_usd(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 4)
  defp fmt_usd(_), do: "0.0000"

  # What period the ledger's totals actually cover. `Budget` keeps its counters
  # in memory only — `init/1` starts them at zero, there is no load and no save
  # on shutdown — so "this month" would be a lie on any run started after the
  # 1st, and badly wrong right after a restart. Say what is true instead.
  defp cost_period_label(%{persisted: false, counting_since: %DateTime{} = since}) do
    "since #{Calendar.strftime(since, "%Y-%m-%d %H:%M")}"
  end

  defp cost_period_label(%{persisted: true}), do: "this month"
  defp cost_period_label(_), do: "this session"

  @doc """
  `/usage` — the provider's report on your account, and OSA's own measurement,
  kept apart.

  A pure read: it never refreshes a credential and never spends a metered
  request to build the display. Where a provider reports nothing it says so
  rather than showing a zero.
  """
  def cmd_usage(args, session_id) do
    all? = String.trim(args) in ["all", "--all", "-a"]

    OptimalSystemAgent.Usage.report(all: all?, session_id: session_id, probe: true)
    |> OptimalSystemAgent.Usage.Render.lines(all: all?)
    |> Enum.each(&IO.puts/1)

    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: usage unavailable#{@reset}\n")
      session_id
  end

  def cmd_context(_args, session_id) do
    IO.puts("")

    max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
    static_tokens = OptimalSystemAgent.Soul.static_token_count()

    case Loop.get_state(session_id) do
      {:ok, state} ->
        total_tokens = state[:tokens_used] || state[:estimated_tokens] || 0
        conversation_tokens = max(total_tokens - static_tokens, 0)
        available = max(max_tokens - total_tokens, 0)
        pct = if max_tokens > 0, do: round(total_tokens / max_tokens * 100), else: 0

        IO.puts("  #{@bold}Context Window Usage (#{pct}%)#{@reset}")

        # Bar
        bar_width = 50
        filled = round(pct / 100 * bar_width)
        empty = bar_width - filled

        bar_color =
          cond do
            pct >= 90 -> @red
            pct >= 70 -> @yellow
            true -> @green
          end

        IO.puts("  #{@dim}┌#{String.duplicate("─", bar_width)}┐#{@reset}")

        IO.puts(
          "  #{@dim}│#{bar_color}#{String.duplicate("█", filled)}#{@dim}#{String.duplicate("░", empty)}#{@reset}#{@dim}│#{@reset}"
        )

        IO.puts("  #{@dim}└#{String.duplicate("─", bar_width)}┘#{@reset}")
        IO.puts("")

        IO.puts(
          "  #{@dim}System prompt:#{@reset}  #{pad_num(static_tokens)} tokens (#{round(static_tokens / max(max_tokens, 1) * 100)}%)"
        )

        IO.puts(
          "  #{@dim}Conversation:#{@reset}   #{pad_num(conversation_tokens)} tokens (#{round(conversation_tokens / max(max_tokens, 1) * 100)}%)"
        )

        IO.puts(
          "  #{@dim}Available:#{@reset}      #{pad_num(available)} tokens (#{round(available / max(max_tokens, 1) * 100)}%)"
        )

        IO.puts("  #{@dim}Total:#{@reset}          #{pad_num(max_tokens)} tokens")

        # Compaction stats
        try do
          comp_stats = Compactor.stats()

          if comp_stats[:compaction_count] && comp_stats[:compaction_count] > 0 do
            IO.puts("")
            IO.puts("  #{@dim}Compressions:#{@reset}   #{comp_stats[:compaction_count]}")

            IO.puts(
              "  #{@dim}Tokens saved:#{@reset}   #{format_tokens(comp_stats[:tokens_saved] || 0)}"
            )
          end
        rescue
          _ -> :ok
        end

      _ ->
        IO.puts("  #{@dim}No active session#{@reset}")
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: context info unavailable#{@reset}\n")
      session_id
  end

  # `/memory` — no arg: stats + recent overview. Verbs: `save <text>` persists
  # a note, `search <q>` / `recall <q>` query the store. The TUI advertises
  # "Save or recall a memory", so the verbs must actually work — previously
  # `_args` was ignored and every invocation printed the same listing.
  def cmd_memory(args, session_id) do
    case String.split(String.trim(args), ~r/\s+/, parts: 2) do
      ["save", content] ->
        IO.puts("")

        try do
          case Memory.save(content, source: :user) do
            {:ok, _entry} -> IO.puts("  #{@green}✓#{@reset} Saved to memory")
            {:error, reason} -> IO.puts("  #{@yellow}error: #{inspect(reason)}#{@reset}")
          end
        rescue
          _ -> IO.puts("  #{@dim}Memory not available#{@reset}")
        end

        IO.puts("")
        session_id

      [verb, query] when verb in ["search", "recall"] ->
        IO.puts("")

        try do
          case Memory.recall(query, limit: 10) do
            {:ok, entries} when is_list(entries) and entries != [] ->
              Enum.each(entries, fn entry ->
                content = entry[:content] || entry[:key] || "?"
                IO.puts("  #{@dim}•#{@reset} #{String.slice(to_string(content), 0, 100)}")
              end)

            _ ->
              IO.puts("  #{@dim}No memories matched \"#{query}\"#{@reset}")
          end
        rescue
          _ -> IO.puts("  #{@dim}Memory not available#{@reset}")
        end

        IO.puts("")
        session_id

      ["save"] ->
        IO.puts("\n  #{@dim}Usage: /memory save <text>#{@reset}\n")
        session_id

      [verb] when verb in ["search", "recall"] ->
        IO.puts("\n  #{@dim}Usage: /memory #{verb} <query>#{@reset}\n")
        session_id

      _ ->
        memory_overview(session_id)
    end
  end

  # `/memory` with no verb: the original stats + recent-entries overview.
  defp memory_overview(session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Memory#{@reset}")

    try do
      {:ok, stats} = Memory.stats()
      total = stats[:total] || stats[:count] || 0
      IO.puts("  #{@dim}Entries:#{@reset} #{total}")

      case Memory.recent(10) do
        {:ok, entries} when is_list(entries) and entries != [] ->
          IO.puts("")

          Enum.each(entries, fn entry ->
            key = entry[:key] || entry[:content] || "?"
            truncated = String.slice(to_string(key), 0, 60)
            IO.puts("  #{@dim}•#{@reset} #{truncated}")
          end)

        _ ->
          IO.puts("  #{@dim}No entries found#{@reset}")
      end
    rescue
      _ ->
        IO.puts("  #{@dim}Memory not available#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_tools(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Available Tools#{@reset}")
    IO.puts("")

    tools = ToolsRegistry.list_tools_direct()

    tools
    |> Enum.sort_by(fn t -> t[:name] || t.name end)
    |> Enum.each(fn tool ->
      name = tool[:name] || tool.name
      desc = tool[:description] || tool.description || ""
      truncated_desc = String.slice(desc, 0, 55)
      padded = String.pad_trailing(name, 22)
      IO.puts("  #{@cyan}#{padded}#{@reset} #{@dim}#{truncated_desc}#{@reset}")
    end)

    IO.puts("")
    IO.puts("  #{@dim}#{length(tools)} tools available#{@reset}")
    IO.puts("")
    session_id
  end

  # ── /skill — list / run / enable / disable / delete / reload ─────────
  #
  # Verb dispatcher reachable from the TUI (POST /commands/execute command="skill"
  # arg="<verb> <rest>") and the CLI REPL. Reuses the existing SkillManager and
  # UseSkill tools so there is exactly ONE implementation of each operation.
  def cmd_skill(args, session_id) do
    {verb, rest} = parse_command(args)
    rest = String.trim(rest)

    case verb do
      v when v in ["", "list", "ls"] ->
        cmd_skills(args, session_id)

      "enable" when rest != "" ->
        print_skill_result(SkillManager.execute(%{"action" => "enable", "name" => rest}))
        session_id

      "disable" when rest != "" ->
        print_skill_result(SkillManager.execute(%{"action" => "disable", "name" => rest}))
        session_id

      "delete" when rest != "" ->
        print_skill_result(SkillManager.execute(%{"action" => "delete", "name" => rest}))
        session_id

      "reload" ->
        print_skill_result(SkillManager.execute(%{"action" => "reload"}))
        session_id

      v when v in ["run", "use"] ->
        {name, task} = parse_command(rest)
        name = String.trim(name)
        task = String.trim(task)

        cond do
          name == "" ->
            IO.puts("  #{@yellow}Usage: /skill run <name> <task>#{@reset}")

          task == "" ->
            IO.puts(
              "  #{@yellow}Usage: /skill run #{name} <task> — a task/prompt is required#{@reset}"
            )

          true ->
            IO.puts("  #{@dim}Running skill '#{name}'...#{@reset}")

            print_skill_result(
              UseSkill.execute(%{
                "skill_name" => name,
                "task" => task,
                "__session_id__" => session_id
              })
            )
        end

        session_id

      v when v in ["enable", "disable", "delete"] ->
        IO.puts("  #{@yellow}Usage: /skill #{v} <name>#{@reset}")
        session_id

      _ ->
        IO.puts(
          "  #{@yellow}Usage: /skill [list|enable <name>|disable <name>|run <name> <task>|reload|delete <name>]#{@reset}"
        )

        session_id
    end
  rescue
    e ->
      IO.puts("  #{@yellow}error: skill command failed: #{Exception.message(e)}#{@reset}\n")
      session_id
  end

  # Render a SkillManager/UseSkill `{:ok, msg}` / `{:error, msg}` result, indented
  # and (for :ok) line-by-line so multi-line skill output stays readable.
  defp print_skill_result({:ok, msg}) do
    IO.puts("")

    msg
    |> to_string()
    |> String.split("\n")
    |> Enum.each(fn line -> IO.puts("  #{line}") end)

    IO.puts("")
  end

  defp print_skill_result({:error, msg}) do
    IO.puts("\n  #{@yellow}#{msg}#{@reset}\n")
  end

  defp print_skill_result(other) do
    IO.puts("\n  #{@yellow}Unexpected skill result: #{inspect(other)}#{@reset}\n")
  end

  def cmd_skills(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Available Skills#{@reset}")
    IO.puts("")

    skills = ToolsRegistry.list_skills()

    # Canonical marker location (beside the skill's own SKILL.md) — the flat
    # `<skills_dir>/<name>/.disabled` guess this used to make was wrong for
    # every nested, renamed or non-user-scope skill.
    disabled? = &OptimalSystemAgent.Tools.Registry.SkillLoader.disabled?/1

    if length(skills) > 0 do
      Enum.each(skills, fn skill ->
        name = skill[:name] || "?"
        desc = skill[:description] || ""
        truncated = String.slice(desc, 0, 48)
        padded = String.pad_trailing(name, 22)

        {status, color} =
          if disabled?.(skill), do: {"disabled", @yellow}, else: {"active", @green}

        IO.puts(
          "  #{@cyan}#{padded}#{@reset} #{color}[#{status}]#{@reset} #{@dim}#{truncated}#{@reset}"
        )
      end)

      disabled_count = Enum.count(skills, disabled?)
      active_count = length(skills) - disabled_count

      IO.puts("")

      IO.puts(
        "  #{@dim}#{length(skills)} skills (#{active_count} active, #{disabled_count} disabled)#{@reset}"
      )

      IO.puts(
        "  #{@dim}/skill enable <name> · /skill disable <name> · /skill run <name> <task>#{@reset}"
      )
    else
      IO.puts("  #{@dim}No skills loaded#{@reset}")
      IO.puts("  #{@dim}Add one at ~/.osa/skills/<name>/SKILL.md, then /skill reload#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # Runtime agent dashboard: live/recent subagent RUNS first (what the agent is
  # actually doing right now), then the available agent ROLES it can spawn.
  def cmd_agents(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Agent Dashboard#{@reset}")
    IO.puts("")

    runs = safe_run_list()

    if runs != [] do
      IO.puts("  #{@dim}Live & recent runs#{@reset}")

      Enum.each(runs, fn run ->
        id = to_string(Map.get(run, :agent_id, "?"))
        role = to_string(Map.get(run, :role, "agent"))
        status = to_string(Map.get(run, :status, "?"))
        icon = run_status_icon(status)
        padded = String.pad_trailing(id, 20)

        IO.puts("  #{icon} #{@cyan}#{padded}#{@reset} #{@dim}#{role} · #{status}#{@reset}")
      end)

      IO.puts("")
    end

    try do
      agents = OptimalSystemAgent.Agents.Registry.list()

      if is_list(agents) and length(agents) > 0 do
        IO.puts("  #{@dim}Available roles#{@reset}")

        Enum.each(agents, fn agent ->
          name = agent[:name] || agent[:role] || "?"
          tier = agent[:tier] || :specialist
          desc = agent[:description] || ""
          truncated = String.slice(desc, 0, 45)
          tier_label = "#{tier}"
          padded = String.pad_trailing(name, 18)

          IO.puts(
            "  #{@cyan}#{padded}#{@reset} #{@dim}[#{tier_label}]#{@reset} #{@dim}#{truncated}#{@reset}"
          )
        end)

        IO.puts("")
        IO.puts("  #{@dim}#{length(runs)} run(s) · #{length(agents)} role(s)#{@reset}")
      else
        if runs == [], do: IO.puts("  #{@dim}No agent runs or roles yet#{@reset}")
      end
    rescue
      _ ->
        if runs == [], do: IO.puts("  #{@dim}Agent registry not available#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # ── /bg — background work (subagent runs + background commands) ───────

  def cmd_bg(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Background Work#{@reset}")
    IO.puts("")

    runs = safe_run_list()

    bg_cmds =
      try do
        OptimalSystemAgent.Shell.BackgroundManager.list()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    if runs == [] and bg_cmds == [] do
      IO.puts("  #{@dim}No background runs or commands.#{@reset}")
    else
      Enum.each(runs, fn run ->
        id = to_string(Map.get(run, :agent_id, "?"))
        role = to_string(Map.get(run, :role, "agent"))
        status = to_string(Map.get(run, :status, "?"))
        icon = run_status_icon(status)
        padded = String.pad_trailing(id, 20)
        IO.puts("  #{icon} #{@cyan}#{padded}#{@reset} #{@dim}#{role} · #{status}#{@reset}")
      end)

      Enum.each(bg_cmds, fn c ->
        id = to_string(Map.get(c, :id, "?"))
        status = to_string(Map.get(c, :status, "?"))
        icon = run_status_icon(status)
        padded = String.pad_trailing(id, 20)
        IO.puts("  #{icon} #{@cyan}#{padded}#{@reset} #{@dim}shell · #{status}#{@reset}")
      end)

      IO.puts("")
      IO.puts("  #{@dim}#{length(runs)} run(s) · #{length(bg_cmds)} command(s)#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # ── /fg — foreground a running agent / fleet node ────────────────────

  @doc """
  Switch the active session to a running agent/fleet node by its run id.

  Minimum-viable foreground switch: validates the id exists in RunStore and is
  live in the SessionRegistry, then RETURNS that id as the REPL's active session
  (subsequent input is routed to it). A true input-handoff that also transfers
  queued/streaming input needs more plumbing — see the note printed on success.
  """
  def cmd_fg(args, session_id) do
    IO.puts("")
    target = String.trim(args)

    cond do
      target == "" ->
        IO.puts("  #{@dim}Usage: /fg <run-id>#{@reset}")

        IO.puts(
          "  #{@dim}Run ids come from /bg or /agents (the live subagent/fleet runs).#{@reset}"
        )

        IO.puts("")
        session_id

      true ->
        run = fg_lookup_run(target)
        live? = fg_live?(target)

        cond do
          is_nil(run) ->
            IO.puts("  #{@yellow}No run found with id #{target}#{@reset}")
            IO.puts("  #{@dim}List runnable ids with /bg or /agents.#{@reset}")
            IO.puts("")
            session_id

          to_string(Map.get(run, :status)) not in ["running", "active", "starting"] ->
            IO.puts(
              "  #{@yellow}Run #{target} is #{Map.get(run, :status)} — only running agents can be foregrounded.#{@reset}"
            )

            IO.puts("")
            session_id

          not live? ->
            IO.puts("  #{@yellow}Run #{target} has no live process to attach to.#{@reset}")
            IO.puts("")
            session_id

          true ->
            role = to_string(Map.get(run, :role, "agent"))

            IO.puts(
              "  #{@green}✓#{@reset} Foregrounded #{@cyan}#{target}#{@reset} #{@dim}(#{role})#{@reset}"
            )

            IO.puts(
              "  #{@dim}Active session switched — your next message goes to this agent. " <>
                "Use /fg <root-id> or /resume to return.#{@reset}"
            )

            IO.puts("")
            # Returning the node id makes it the REPL's active session (dispatch
            # contract: cmd handlers return the new session_id).
            target
        end
    end
  rescue
    _ ->
      IO.puts("  #{@yellow}error: could not foreground run#{@reset}\n")
      session_id
  end

  defp fg_lookup_run(id) do
    OptimalSystemAgent.Agent.RunStore.get(id)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp fg_live?(id) do
    OptimalSystemAgent.Runtime.SessionManager.live_session?(id)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp safe_run_list do
    OptimalSystemAgent.Agent.RunStore.list(limit: 20)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp run_status_icon(status) do
    case to_string(status) do
      s when s in ["running", "active", "starting"] -> "#{@yellow}◐#{@reset}"
      s when s in ["done", "completed", "ok"] -> "#{@green}●#{@reset}"
      s when s in ["failed", "error"] -> "#{@red}○#{@reset}"
      "killed" -> "#{@red}○#{@reset}"
      "cancelled" -> "#{@dim}○#{@reset}"
      _ -> "#{@dim}○#{@reset}"
    end
  end

  # ── /steer — inject a directive into the running turn ────────────────

  def cmd_steer(args, session_id) do
    alias OptimalSystemAgent.Agent.Loop
    alias OptimalSystemAgent.Runtime.SessionManager

    IO.puts("")
    text = String.trim(args)

    cond do
      text == "" ->
        IO.puts("  #{@dim}Usage: /steer <directive>#{@reset}")
        IO.puts("  #{@dim}Folds guidance into the RUNNING turn without cancelling it.#{@reset}")

      SessionManager.live_session?(session_id) ->
        Loop.steer(session_id, text)

        IO.puts(
          "  #{@green}✓#{@reset} Steer queued — the agent folds it in at its next step boundary"
        )

      true ->
        # No live turn: still queue it (drains on the next turn) so nothing is lost.
        Loop.steer(session_id, text)
        IO.puts("  #{@dim}No turn running — directive queued for the next step.#{@reset}")
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: could not steer#{@reset}\n")
      session_id
  end

  def cmd_sessions(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Active Sessions#{@reset}")
    IO.puts("")

    try do
      sessions =
        Registry.select(OptimalSystemAgent.SessionRegistry, [
          {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
        ])

      if length(sessions) > 0 do
        Enum.each(sessions, fn {sid, _pid, _meta} ->
          marker = if sid == session_id, do: "#{@green}*#{@reset}", else: " "

          case OptimalSystemAgent.Memory.SessionTitler.display_title(sid) do
            title when is_binary(title) and title != "" ->
              IO.puts("  #{marker} #{title}  #{@dim}#{sid}#{@reset}")

            _ ->
              IO.puts("  #{marker} #{@dim}#{sid}#{@reset}")
          end
        end)
      else
        IO.puts("  #{@dim}#{session_id}#{@reset} #{@green}(current)#{@reset}")
      end
    rescue
      _ ->
        IO.puts("  #{@dim}#{session_id}#{@reset} #{@green}(current)#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_tasks(_args, session_id) do
    IO.puts("")

    try do
      tasks = Tasks.get_tasks(session_id)

      if is_list(tasks) and length(tasks) > 0 do
        IO.puts(TaskDisplay.render(tasks, Renderer.terminal_width() - 4))
      else
        IO.puts("  #{@dim}No active tasks#{@reset}")
      end
    rescue
      _ ->
        IO.puts("  #{@dim}Task tracker not available#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_plan(_args, session_id) do
    IO.puts("")

    case Loop.toggle_plan_mode(session_id) do
      {:ok, true} ->
        IO.puts(
          "  #{@green}#{@reset} Plan mode #{@bold}enabled#{@reset} — agent will propose a plan before acting"
        )

      {:ok, false} ->
        IO.puts("  #{@green}#{@reset} Plan mode #{@bold}disabled#{@reset}")

      {:error, :no_session} ->
        IO.puts("  #{@yellow}error: session not found#{@reset}")

      {:error, _reason} ->
        IO.puts("  #{@yellow}error: could not toggle plan mode#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_doctor(args, session_id) do
    IO.puts("")
    # Pass the args through: `Doctor.run/1` already dispatches `--config` /
    # `--all` to the setup-inspection report, but the TUI dropped its args and
    # called `run/0`, so `/doctor --config` was silently the plain health
    # report and the inspection report was reachable ONLY from `osa doctor
    # --config` outside a session. An empty arg list takes the `run/0` branch,
    # so bare `/doctor` is unchanged.
    OptimalSystemAgent.CLI.Doctor.run(String.split(String.trim(args), ~r/\s+/, trim: true))
    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: doctor not available#{@reset}\n")
      session_id
  end

  def cmd_version(_args, session_id) do
    alias OptimalSystemAgent.ReleaseNotes

    version = ReleaseNotes.current_version()

    hash =
      try do
        case OptimalSystemAgent.Git.cmd(["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
          {h, 0} -> " (#{String.trim(h)})"
          _ -> ""
        end
      rescue
        _ -> ""
      end

    IO.puts("\n  #{@bold}OSA#{@reset} #{@dim}v#{version}#{hash}#{@reset}")

    # Version-check: compare against the latest known release tag.
    case ReleaseNotes.version_status() do
      %{update_available: true, latest: latest} ->
        IO.puts(
          "  #{@yellow}↑#{@reset} #{@bold}v#{latest}#{@reset} #{@dim}available — run#{@reset} " <>
            "#{@cyan}osa update#{@reset} #{@dim}to upgrade, then#{@reset} #{@cyan}/release-notes#{@reset}"
        )

      %{latest: latest} ->
        IO.puts("  #{@green}✓#{@reset} #{@dim}up to date (latest v#{latest})#{@reset}")

      _ ->
        :ok
    end

    IO.puts("")
    session_id
  end

  def cmd_release_notes(args, session_id) do
    alias OptimalSystemAgent.ReleaseNotes

    n =
      case Integer.parse(String.trim(args)) do
        {count, _} when count > 0 -> min(count, 10)
        _ -> 1
      end

    IO.puts("")

    IO.puts(
      "  #{@bold}What's New#{@reset} #{@dim}(OSA v#{ReleaseNotes.current_version()})#{@reset}"
    )

    IO.puts("")

    text = ReleaseNotes.latest_text(n)

    text
    |> String.split("\n")
    |> Enum.each(fn line -> IO.puts("  #{line}") end)

    IO.puts("")
    session_id
  end

  def cmd_export(args, session_id) do
    IO.puts("")

    export_dir = Path.expand("~/.osa/exports")
    File.mkdir_p!(export_dir)

    target_id =
      case String.trim(args) do
        "" -> session_id
        id -> id
      end

    transcript = OptimalSystemAgent.Store.SessionTranscript.get_transcript(target_id)

    if transcript == [] do
      IO.puts("  #{@dim}No transcript data for #{target_id}#{@reset}")
      IO.puts("  #{@dim}(Transcripts are saved after each response)#{@reset}")
    else
      md_lines =
        Enum.map(transcript, fn t ->
          role = String.capitalize(to_string(t.role))
          ts = t.inserted_at || ""
          "### #{role} (#{ts})\n\n#{t.content}\n"
        end)

      markdown = "# Session Export: #{target_id}\n\n" <> Enum.join(md_lines, "\n---\n\n")
      filename = "#{target_id}.md"
      path = Path.join(export_dir, filename)
      File.write!(path, markdown)

      IO.puts("  #{@green}✓#{@reset} Exported #{length(transcript)} turns to:")
      IO.puts("  #{@cyan}#{path}#{@reset}")
    end

    IO.puts("")
    session_id
  rescue
    e ->
      IO.puts("  #{@yellow}error: #{Exception.message(e)}#{@reset}\n")
      session_id
  end

  def cmd_effort(args, session_id) do
    alias OptimalSystemAgent.Agent.Effort
    IO.puts("")

    case String.trim(args) do
      s when s in ["", "current", "status"] ->
        current = Effort.current()
        config = Effort.get(current)
        IO.puts("  #{@bold}Effort Level: #{current}#{@reset}")
        IO.puts("  #{@dim}#{config.description}#{@reset}")
        IO.puts("")
        IO.puts("  #{@dim}Thinking budget:#{@reset} #{config.thinking_budget} tokens")
        IO.puts("  #{@dim}Max iterations:#{@reset}  #{config.max_iterations}")
        IO.puts("  #{@dim}Temperature:#{@reset}     #{config.temperature}")
        IO.puts("")
        IO.puts("  #{@dim}Usage: /effort fast|medium|high|xhigh|ultra#{@reset}")

      level_str ->
        # Effort.set normalizes legacy names (low→fast, max→xhigh) and validates.
        case Effort.set(level_str) do
          :ok ->
            level = Effort.current()
            config = Effort.get(level)

            IO.puts(
              "  #{@green}✓#{@reset} Effort set to #{@bold}#{level}#{@reset} — #{config.description}"
            )

          {:error, _} ->
            IO.puts("  #{@yellow}error: invalid level '#{level_str}'#{@reset}")
            IO.puts("  #{@dim}Valid levels: fast, medium, high, xhigh, ultra#{@reset}")
        end
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: invalid level#{@reset}")
      IO.puts("  #{@dim}Valid levels: fast, medium, high, xhigh, ultra#{@reset}\n")
      session_id
  end

  def cmd_fast(_args, session_id) do
    alias OptimalSystemAgent.Agent.Effort
    IO.puts("")

    Effort.toggle_fast()
    config = Effort.get(Effort.current())

    mode =
      if Effort.fast_mode?(),
        do: "enabled",
        else: "disabled"

    IO.puts("  #{@green}✓#{@reset} Fast mode #{@bold}#{mode}#{@reset}")
    IO.puts("  #{@dim}Effort:#{@reset}     #{Effort.current()}")
    IO.puts("  #{@dim}Iterations:#{@reset} #{config.max_iterations}")
    IO.puts("  #{@dim}Output cap:#{@reset} #{config.max_response_tokens} tokens")
    IO.puts("  #{@dim}Tool cap:#{@reset}   #{config.tool_budget}")

    IO.puts("")
    session_id
  end

  def cmd_coordinator(_args, session_id) do
    IO.puts("")

    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] ->
        try do
          state = :sys.get_state(pid)
          current = state.coordinator || false

          if current do
            # Restart session without coordinator mode
            new_id = Session.start_new_session(session_id)

            IO.puts(
              "  #{@green}✓#{@reset} Coordinator mode #{@bold}disabled#{@reset} — full tool access restored"
            )

            IO.puts("")
            new_id
          else
            # Restart session in coordinator mode
            Session.stop_session(session_id)
            new_id = "cli_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"

            {:ok, _pid} =
              DynamicSupervisor.start_child(
                OptimalSystemAgent.SessionSupervisor,
                {OptimalSystemAgent.Agent.Loop,
                 session_id: new_id, channel: :cli, coordinator: true}
              )

            Session.register_permission_hook(new_id)

            IO.puts(
              "  #{@green}✓#{@reset} Coordinator mode #{@bold}enabled#{@reset} — tools restricted to delegation and messaging"
            )

            IO.puts("  #{@dim}  session: #{new_id}#{@reset}")
            IO.puts("")
            new_id
          end
        rescue
          _ ->
            IO.puts("  #{@yellow}error: could not toggle coordinator mode#{@reset}")
            IO.puts("")
            session_id
        end

      _ ->
        IO.puts("  #{@yellow}error: session not found#{@reset}")
        IO.puts("")
        session_id
    end
  end

  # ── /login, /logout — real account sign-in ────────────────────────────
  #
  # These once ran an Anthropic OAuth flow with Claude Code's first-party
  # client id; that was removed (see `Auth.LegacyAnthropicOAuth`) and for one
  # release the commands were left printing "no provider supports account
  # sign-in", which stopped being true the moment the first subscription
  # provider shipped. They now drive the real thing, and share every line of
  # their behaviour with `osa auth` so the REPL and the terminal can never
  # disagree about who is signed in.

  def cmd_login(args, session_id) do
    case String.trim(args) do
      "" ->
        OptimalSystemAgent.CLI.Auth.status()

        IO.puts(
          "  #{@dim}Sign in with#{@reset}  #{@cyan}/login <provider>#{@reset}  " <>
            "#{@dim}— or paste a key with#{@reset}  #{@cyan}/setup#{@reset}"
        )

        IO.puts("")

      provider ->
        _ = OptimalSystemAgent.CLI.Auth.login(provider)
    end

    session_id
  end

  def cmd_logout(args, session_id) do
    case String.trim(args) do
      "" ->
        # Naming the provider is required rather than guessed. Signing a user
        # out of something they did not name is the kind of "helpful" default
        # that costs them a re-authentication.
        OptimalSystemAgent.CLI.Auth.status()

        IO.puts("  #{@dim}Sign out with#{@reset}  #{@cyan}/logout <provider>#{@reset}")
        IO.puts("")

      "--all" ->
        _ = OptimalSystemAgent.CLI.Auth.logout_all()

      provider ->
        _ = OptimalSystemAgent.CLI.Auth.logout(provider)
    end

    if OptimalSystemAgent.Auth.LegacyAnthropicOAuth.purged?() do
      IO.puts(
        "  #{@dim}A stale ~/.osa/oauth.json from the removed Anthropic sign-in was deleted.#{@reset}"
      )

      IO.puts("")
    end

    session_id
  end

  def cmd_setup(_args, session_id) do
    IO.puts("")
    OptimalSystemAgent.CLI.Setup.run()
    IO.puts("")
    session_id
  end

  # ── /customize — "make OSA yours" cheat-sheet + starter-template seeding ──
  #
  # Prints where every customization surface lives under ~/.osa/ and, with the
  # `seed` argument, copies the starter templates into place using the existing
  # `Onboarding.seed_workspace/0` "only-if-not-exists" guard (never overwrites).

  @customize_rows [
    {"IDENTITY.md", "who OSA is — name, role, personality"},
    {"SOUL.md", "voice & values — how OSA speaks and decides"},
    {"USER.md", "your profile — who OSA is working for"},
    {"HEARTBEAT.md", "proactive work OSA does on its own when idle"},
    {"CRONS.json", "scheduled tasks that run on a recurring timer"},
    {"TRIGGERS.json", "event-driven tasks fired when something happens"},
    {"config.json", "provider/model, budgets, machines, channels"},
    {"skills/<name>/SKILL.md", "reusable skills OSA can load on demand"},
    {"commands/<name>.md", "custom /slash commands — body becomes the prompt ($ARGUMENTS)"},
    {"workflows/<id>.json", "multi-step workflow templates"}
  ]

  def cmd_customize(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "seed" ->
        seed_customize_templates()

      _ ->
        print_customize_cheatsheet()
    end

    IO.puts("")
    session_id
  end

  defp print_customize_cheatsheet do
    osa_dir = Path.expand("~/.osa")

    IO.puts("  #{@bold}Make OSA yours#{@reset}")

    IO.puts(
      "  #{@dim}OSA works out of the box — everything below is optional and lives in #{osa_dir}/#{@reset}"
    )

    IO.puts("")

    Enum.each(@customize_rows, fn {path, purpose} ->
      exists? = File.exists?(Path.join(osa_dir, hd(String.split(path, "/"))))
      marker = if exists?, do: "#{@green}●#{@reset}", else: "#{@dim}○#{@reset}"
      padded = String.pad_trailing("~/.osa/#{path}", 26)
      IO.puts("  #{marker} #{@cyan}#{padded}#{@reset} #{@dim}#{purpose}#{@reset}")
    end)

    IO.puts("")

    IO.puts(
      "  #{@dim}See examples/ (or examples/README.md) for ready-to-copy templates.#{@reset}"
    )

    IO.puts(
      "  #{@dim}Run #{@reset}#{@cyan}/customize seed#{@reset}#{@dim} to copy starter templates into ~/.osa/ (never overwrites).#{@reset}"
    )
  end

  defp seed_customize_templates do
    osa_dir = Path.expand("~/.osa")

    before = MapSet.new(list_osa_files(osa_dir))
    OptimalSystemAgent.Onboarding.seed_workspace()
    seeded = list_osa_files(osa_dir) |> Enum.reject(&MapSet.member?(before, &1)) |> Enum.sort()

    cond do
      seeded != [] ->
        IO.puts("  #{@green}✓#{@reset} Seeded starter templates into #{osa_dir}/:")

        Enum.each(seeded, fn f ->
          IO.puts("    #{@cyan}#{f}#{@reset}")
        end)

      true ->
        IO.puts(
          "  #{@dim}All starter templates already present in #{osa_dir}/ — nothing to copy.#{@reset}"
        )
    end

    IO.puts(
      "  #{@dim}Existing files were left untouched. Edit them, then restart OSA to apply.#{@reset}"
    )
  rescue
    e ->
      IO.puts("  #{@yellow}error: could not seed templates: #{Exception.message(e)}#{@reset}")
  end

  defp list_osa_files(osa_dir) do
    case File.ls(osa_dir) do
      {:ok, files} -> files
      _ -> []
    end
  end

  def cmd_channels(_args, session_id) do
    alias OptimalSystemAgent.Channels.Manager

    channels = Manager.list_channels()

    IO.puts("")
    IO.puts("  #{@bold}Messaging Channels#{@reset}")
    IO.puts("")

    if channels == [] do
      IO.puts("  #{@dim}No channels configured#{@reset}")
    else
      for ch <- channels do
        status =
          if ch.connected,
            do: "#{@green}● connected#{@reset}",
            else: "#{@dim}○ not running#{@reset}"

        IO.puts("  #{@cyan}#{String.pad_trailing(to_string(ch.name), 12)}#{@reset} #{status}")
      end
    end

    IO.puts("")
    IO.puts("  #{@dim}Configure channels with /setup or set env vars#{@reset}")
    IO.puts("  #{@dim}Docs: TELEGRAM_BOT_TOKEN, DISCORD_BOT_TOKEN, etc.#{@reset}")
    IO.puts("")

    session_id
  rescue
    _ ->
      IO.puts("  #{@dim}Channel status unavailable#{@reset}\n")
      session_id
  end

  def cmd_resume(args, session_id) do
    alias OptimalSystemAgent.Agent.SessionPersistence
    IO.puts("")

    case String.trim(args) do
      "" ->
        sessions = SessionPersistence.list(limit: 10)

        if sessions == [] do
          IO.puts("  #{@dim}No saved sessions found.#{@reset}")
        else
          IO.puts("  #{@bold}Recent Sessions#{@reset}")
          IO.puts("")

          Enum.each(sessions, fn session ->
            id = session.session_id
            mtime = session.modified_at

            date_str =
              try do
                NaiveDateTime.to_string(mtime) |> String.slice(0, 16)
              rescue
                _ -> "?"
              end

            preview =
              try do
                case SessionPersistence.load(id) do
                  {:ok, msgs} when is_list(msgs) ->
                    first_user =
                      Enum.find(msgs, fn m ->
                        (m[:role] || m["role"]) == "user"
                      end)

                    if first_user do
                      content = first_user[:content] || first_user["content"] || ""
                      String.slice(content, 0, 70)
                    else
                      ""
                    end

                  _ ->
                    ""
                end
              rescue
                _ -> ""
              end

            # What the session was ABOUT leads the row; the opaque id is the
            # thing you type, not the thing you scan for.
            title =
              OptimalSystemAgent.Memory.SessionTitler.display_title(id) || session[:title]

            if is_binary(title) and title != "" do
              IO.puts("  #{@bold}#{title}#{@reset}")
              IO.puts("  #{@cyan}#{id}#{@reset}  #{@dim}#{date_str}#{@reset}")
            else
              IO.puts("  #{@cyan}#{id}#{@reset}  #{@dim}#{date_str}#{@reset}")
            end

            if preview != "" do
              IO.puts("    #{@dim}#{preview}#{@reset}")
            end
          end)

          IO.puts("")
          IO.puts("  #{@dim}Usage: /resume <session_id>#{@reset}")
        end

        IO.puts("")
        session_id

      target_id ->
        case SessionPersistence.load(target_id) do
          {:ok, messages} when is_list(messages) and messages != [] ->
            IO.puts("  #{@green}Resuming session #{target_id}...#{@reset}")
            Session.resume_session(target_id, messages, session_id)

          {:ok, []} ->
            IO.puts("  #{@yellow}Session #{target_id} has no messages.#{@reset}\n")
            session_id

          {:error, :not_found} ->
            IO.puts("  #{@red}Session '#{target_id}' not found.#{@reset}\n")
            session_id

          {:error, reason} ->
            IO.puts("  #{@red}Failed to load session: #{inspect(reason)}#{@reset}\n")
            session_id
        end
    end
  rescue
    e ->
      IO.puts("  #{@red}Resume error: #{Exception.message(e)}#{@reset}\n")
      session_id
  end

  def cmd_persona(args, session_id) do
    alias OptimalSystemAgent.Personality
    IO.puts("")

    case String.trim(args) do
      "" ->
        current = Personality.current()
        presets = Personality.list()

        IO.puts("  #{@bold}Persona Presets#{@reset}")
        IO.puts("")

        Enum.each(presets, fn preset ->
          marker = if preset.name == current, do: "#{@green}*#{@reset}", else: " "
          padded = String.pad_trailing(preset.name, 14)
          IO.puts("  #{marker} #{@cyan}#{padded}#{@reset} #{@dim}#{preset.description}#{@reset}")
        end)

        IO.puts("")
        IO.puts("  #{@dim}Current: #{current}. Usage: /persona <name>#{@reset}")

      name ->
        case Personality.set(name) do
          :ok ->
            preset = Enum.find(Personality.list(), &(&1.name == name))
            desc = if preset, do: preset.description, else: name

            IO.puts(
              "  #{@green}Persona set to #{@bold}#{name}#{@reset}#{@green} — #{desc}#{@reset}"
            )

          {:error, reason} ->
            IO.puts("  #{@red}#{reason}#{@reset}")
        end
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: personality switch failed#{@reset}\n")
      session_id
  end

  def cmd_exit(_args, _session_id) do
    Renderer.print_goodbye()
    System.halt(0)
  end

  # ── Parsing & Suggestions ────────────────────────────────────────────

  defp parse_command(input) do
    parts = String.split(input, ~r/\s+/, parts: 2)

    case parts do
      [cmd] -> {String.downcase(cmd), ""}
      [cmd, args] -> {String.downcase(cmd), args}
      _ -> {input, ""}
    end
  end

  defp suggest_similar(cmd_name) do
    candidates = Map.keys(@commands)

    best =
      candidates
      |> Enum.map(fn c -> {c, String.jaro_distance(cmd_name, c)} end)
      |> Enum.filter(fn {_c, score} -> score > 0.7 end)
      |> Enum.sort_by(fn {_c, score} -> score end, :desc)
      |> Enum.take(3)

    IO.puts("#{@yellow}  error: unknown command '/#{cmd_name}'#{@reset}")

    case best do
      [{suggestion, _score} | _] ->
        IO.puts("#{@dim}  Did you mean /#{suggestion}?#{@reset}\n")

      [] ->
        IO.puts("#{@dim}  Type /help to see available commands#{@reset}\n")
    end
  end

  # ── Helpers (delegates to shared Format module) ──────────────────────

  alias OptimalSystemAgent.Channels.CLI.Format

  defp format_tokens(n), do: Format.format_tokens(n)
  defp pad_num(n), do: String.pad_leading(format_tokens(n), 8)
  defp get_model_name(provider), do: Format.get_model_name(provider)

  defp format_context_window(n), do: Format.format_context_window(n)

  # Parse a `/model` argument into an explicit provider+model or a bare model.
  # Supports "provider/model", "provider model", and "model" (provider resolved
  # from the Catalog / heuristic by the caller). A leading token is only treated
  # as a provider when it names a REGISTERED provider — otherwise the whole arg
  # is a model id (many ids legitimately contain "/", e.g. "meta-llama/…").
  defp parse_model_arg(arg) do
    cond do
      String.contains?(arg, "/") ->
        [head, rest] = String.split(arg, "/", parts: 2)

        case atomize_provider(head) do
          nil -> {:model_only, arg}
          provider when rest != "" -> {:explicit, provider, rest}
          _ -> {:model_only, arg}
        end

      true ->
        case String.split(arg, ~r/\s+/, parts: 2, trim: true) do
          [head, rest] ->
            case atomize_provider(head) do
              nil -> {:model_only, arg}
              provider -> {:explicit, provider, rest}
            end

          _ ->
            {:model_only, arg}
        end
    end
  end

  # Resolve a provider token to a registered provider atom, or nil.
  defp atomize_provider(token) do
    Enum.find(ProviderRegistry.list_providers(), fn a -> Atom.to_string(a) == token end)
  end

  # ── Permission Management ────────────────────────────────────────────

  def cmd_permissions(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "" ->
        rules = OptimalSystemAgent.Permissions.list_rules()

        if map_size(rules) == 0 do
          IO.puts("  #{@dim}No permission rules configured.#{@reset}")

          IO.puts(
            "  #{@dim}Rules are saved when you choose 'Allow always' on a permission prompt.#{@reset}"
          )
        else
          IO.puts("  #{@bold}Permission Rules#{@reset}")
          IO.puts("")

          Enum.each(rules, fn {tool, action} ->
            icon =
              if action == "allow",
                do: "#{IO.ANSI.green()}✓#{@reset}",
                else: "#{IO.ANSI.red()}✗#{@reset}"

            IO.puts("  #{icon} #{tool} → #{action}")
          end)
        end

        IO.puts("")
        IO.puts("  #{@dim}Usage: /permissions add <tool> <allow|deny> | remove <tool>#{@reset}")

      "remove " <> tool_name ->
        Permissions.remove_rule(String.trim(tool_name))
        IO.puts("  #{IO.ANSI.green()}✓#{@reset} Removed rule for #{String.trim(tool_name)}")

      "add " <> rest ->
        case String.split(String.trim(rest), ~r/\s+/, parts: 2) do
          [tool, action] when action in ["allow", "deny"] and tool != "" ->
            decision = if action == "allow", do: :allow_always, else: :deny_always
            Permissions.save_rule(tool, decision)
            IO.puts("  #{IO.ANSI.green()}✓#{@reset} Added rule: #{tool} → #{action}")

          _ ->
            IO.puts("  #{@dim}Usage: /permissions add <tool> <allow|deny>#{@reset}")
        end

      _ ->
        IO.puts("  #{@dim}Usage: /permissions [add <tool> <allow|deny> | remove <tool>]#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # ── Additional Directories (/add-dir) ────────────────────────────────

  def cmd_add_dir(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "" ->
        dirs = Permissions.additional_directories()

        if dirs == [] do
          IO.puts("  #{@dim}No additional directories configured.#{@reset}")
        else
          IO.puts("  #{@bold}Additional Directories#{@reset}")
          Enum.each(dirs, fn d -> IO.puts("  #{@green}+#{@reset} #{d}") end)
        end

        IO.puts("  #{@dim}Usage: /add-dir <path>#{@reset}")

      raw ->
        path = Path.expand(raw)

        cond do
          not File.exists?(path) ->
            IO.puts("  #{@red}error:#{@reset} #{path} does not exist")

          not File.dir?(path) ->
            IO.puts("  #{@red}error:#{@reset} #{path} is not a directory")

          true ->
            :ok = Permissions.add_directory(path)
            IO.puts("  #{@green}✓#{@reset} Added working directory: #{path}")
        end
    end

    IO.puts("")
    session_id
  end

  # ── Workspace Trust (/trust) ─────────────────────────────────────────

  def cmd_trust(args, session_id) do
    IO.puts("")
    cwd = File.cwd!()

    case String.trim(args) do
      "accept" ->
        :ok = OptimalSystemAgent.Workspace.Trust.accept(cwd)
        IO.puts("  #{@green}✓#{@reset} Workspace trusted: #{cwd}")
        IO.puts("  #{@dim}Project hooks and workspace config are now active.#{@reset}")

      "" ->
        status = OptimalSystemAgent.Workspace.Trust.status(cwd)

        state =
          cond do
            status.trusted and status.session_only ->
              "#{@green}trusted#{@reset} (this session only)"

            status.trusted ->
              "#{@green}trusted#{@reset}"

            true ->
              "#{@yellow}not trusted#{@reset}"
          end

        IO.puts("  #{@bold}Workspace#{@reset} #{cwd} — #{state}")

        if status.risks != [] do
          IO.puts("")
          IO.puts("  #{@bold}Workspace-supplied config found here:#{@reset}")
          Enum.each(status.risks, fn r -> IO.puts("  #{@yellow}!#{@reset} #{r.label}") end)
        end

        unless status.trusted do
          IO.puts("")

          IO.puts(
            "  #{@dim}Project hooks stay inert until trusted. /trust accept to trust this directory.#{@reset}"
          )
        end

      _ ->
        IO.puts("  #{@dim}Usage: /trust [accept]#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # ── Hooks Viewer ─────────────────────────────────────────────────────

  def cmd_hooks(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Registered Hooks#{@reset}")
    IO.puts("")

    try do
      hooks = OptimalSystemAgent.Agent.Hooks.list_hooks()

      if is_list(hooks) and length(hooks) > 0 do
        hooks
        |> Enum.sort_by(fn h -> {h[:event], h[:priority]} end)
        |> Enum.each(fn hook ->
          event = hook[:event] || "?"
          name = hook[:name] || "?"
          priority = hook[:priority] || 0
          IO.puts("  #{@cyan}#{event}#{@reset} #{@dim}p#{priority}#{@reset} #{name}")
        end)

        IO.puts("")
        IO.puts("  #{@dim}#{length(hooks)} hooks registered#{@reset}")
      else
        IO.puts("  #{@dim}No hooks registered.#{@reset}")
      end
    rescue
      _ -> IO.puts("  #{@dim}Hooks system not available.#{@reset}")
    end

    # Settings-configured hooks (CC-style entries from the user/project/local
    # settings cascade), listed per event. Project-layer entries only appear
    # once the workspace is trusted (see Settings.get_merged_hooks).
    try do
      merged = OptimalSystemAgent.Settings.get_merged_hooks()

      if map_size(merged) > 0 do
        IO.puts("")
        IO.puts("  #{@bold}Settings Hooks#{@reset}")

        merged
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.each(fn {event, entries} ->
          Enum.each(entries, fn entry ->
            label =
              case entry do
                %{"matcher" => m, "hooks" => hs} when is_list(hs) ->
                  "matcher=#{inspect(m)} (#{length(hs)} hook(s))"

                %{"command" => command} ->
                  command

                other ->
                  other |> inspect() |> String.slice(0, 80)
              end

            IO.puts("  #{@cyan}#{event}#{@reset} #{label}")
          end)
        end)
      end
    rescue
      _ -> :ok
    end

    IO.puts("")
    session_id
  end

  # ── Metrics Viewer ───────────────────────────────────────────────────

  def cmd_metrics(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Telemetry Metrics#{@reset}")
    IO.puts("")

    try do
      snapshot = OptimalSystemAgent.Telemetry.Metrics.snapshot()

      if map_size(snapshot.tools) > 0 do
        IO.puts("  #{@bold}Tools#{@reset}")

        Enum.each(snapshot.tools, fn {name, stats} ->
          IO.puts(
            "  #{@cyan}#{String.pad_trailing(to_string(name), 20)}#{@reset}" <>
              " #{stats.count} calls" <>
              " #{@dim}avg #{stats.avg_ms}ms#{@reset}" <>
              " #{@dim}p99 #{stats.p99_ms}ms#{@reset}" <>
              " #{@dim}#{stats.success}✓ #{stats.fail}✗#{@reset}"
          )
        end)

        IO.puts("")
      end

      if map_size(snapshot.providers) > 0 do
        IO.puts("  #{@bold}Providers#{@reset}")

        Enum.each(snapshot.providers, fn {name, stats} ->
          IO.puts(
            "  #{@cyan}#{String.pad_trailing(to_string(name), 20)}#{@reset}" <>
              " #{stats.count} calls" <>
              " #{@dim}avg #{stats.avg_ms}ms#{@reset}" <>
              " #{@dim}p99 #{stats.p99_ms}ms#{@reset}"
          )
        end)

        IO.puts("")
      end

      IO.puts("  #{@dim}Total turns: #{snapshot.sessions.total_turns}#{@reset}")
    rescue
      _ -> IO.puts("  #{@dim}Metrics not available.#{@reset}")
    end

    IO.puts("")
    session_id
  end

  # ── MCP Servers ──────────────────────────────────────────────────────

  def cmd_mcp(args, session_id) do
    case String.split(String.trim(to_string(args)), ~r/\s+/, trim: true) do
      [] -> mcp_status(session_id)
      ["list" | _] -> mcp_status(session_id)
      ["add" | opts] -> mcp_add(opts, session_id)
      [rm | opts] when rm in ["remove", "rm"] -> mcp_remove(opts, session_id)
      ["get", name | _] -> mcp_get(name, session_id)
      ["exclude"] -> mcp_exclude_list(session_id)
      ["exclude", name | _] -> mcp_exclude(name, session_id)
      [un, name | _] when un in ["unexclude", "include"] -> mcp_unexclude(name, session_id)
      _ -> mcp_usage(session_id)
    end
  end

  defp mcp_status(session_id) do
    IO.puts("")
    IO.puts("  #{@bold}MCP Servers#{@reset}")
    IO.puts("")

    running =
      try do
        MCP.Client.Manager.list_servers()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    cond do
      running != [] ->
        Enum.each(running, fn s ->
          {icon, label} = mcp_status_display(s[:status])
          tools = s[:tool_count] || 0

          IO.puts(
            "  #{icon} #{@cyan}#{String.pad_trailing(to_string(s[:name]), 20)}#{@reset}" <>
              " #{@dim}#{s[:transport]} · #{label} · #{tools} tools · " <>
              "#{mcp_origin(s[:source], s[:scope])}#{@reset}"
          )
        end)

        total_tools = Enum.reduce(running, 0, fn s, acc -> acc + (s[:tool_count] || 0) end)

        IO.puts("")

        IO.puts("  #{@dim}#{length(running)} server(s) · #{total_tools} tools total#{@reset}")

      true ->
        configured =
          case MCP.Config.load() do
            {:ok, list} -> list
            _ -> []
          end

        if configured == [] do
          IO.puts("  #{@dim}No MCP servers configured.#{@reset}")
          IO.puts("  #{@dim}Add servers to #{MCP.Config.config_path()}#{@reset}")
        else
          Enum.each(configured, fn s ->
            IO.puts(
              "  #{@dim}○#{@reset} #{@cyan}#{String.pad_trailing(s.name, 20)}#{@reset}" <>
                " #{@dim}#{s.transport} · not started · #{mcp_origin(s.source, s.scope)}#{@reset}"
            )
          end)

          IO.puts("")

          IO.puts(
            "  #{@dim}#{length(configured)} server(s) configured (manager offline)#{@reset}"
          )
        end
    end

    mcp_import_footer()

    IO.puts("")
    session_id
  end

  # "Where did this server come from?" — the attribution line. `:osa` source
  # means one of OSA's own config files (named by scope); anything else was
  # inherited from another tool's config, which is only possible when the
  # operator opted into `mcp_import_foreign`.
  defp mcp_origin(source, scope) do
    case source || :osa do
      :osa ->
        case scope || :user do
          :user -> "osa config (~/.osa/mcp.json)"
          :project -> "project (.mcp.json)"
          :local -> "project-local (.osa/mcp.local.json)"
          other -> "osa config (#{other})"
        end

      foreign ->
        path = MCP.Discovery.source_path(foreign)
        label = MCP.Discovery.source_label(foreign)
        if path, do: "#{label} (#{path})", else: label
    end
  end

  # Report the state of foreign-config import, and — when it is off — how many
  # servers COULD be inherited plus how to opt in. This is the whole point of
  # making the import opt-in: the operator can still see what exists without
  # OSA having quietly run it.
  defp mcp_import_footer do
    excluded = MCP.Config.exclusions() |> Enum.sort()

    if excluded != [] do
      IO.puts("")
      IO.puts("  #{@dim}excluded: #{Enum.join(excluded, ", ")} (/mcp unexclude <name>)#{@reset}")
    end

    IO.puts("")

    if MCP.Discovery.import_enabled?() do
      IO.puts(
        "  #{@dim}Importing MCP servers from other tools is ON " <>
          "(settings: mcp_import_foreign). Turn off to run only OSA's own servers.#{@reset}"
      )
    else
      available =
        try do
          MCP.Discovery.available()
        rescue
          _ -> []
        end

      if available != [] do
        by_source =
          available
          |> Enum.group_by(& &1.source)
          |> Enum.map_join(", ", fn {src, list} -> "#{length(list)} from #{src}" end)

        IO.puts(
          "  #{@dim}#{length(available)} server(s) available in other tools' configs " <>
            "(#{by_source}) — NOT imported.#{@reset}"
        )

        IO.puts("  #{@dim}Import them with: /settings set mcp_import_foreign true#{@reset}")
      end
    end
  rescue
    _ -> :ok
  end

  defp mcp_exclude_list(session_id) do
    IO.puts("")

    case MCP.Config.exclusions() |> Enum.sort() do
      [] ->
        IO.puts("  #{@dim}No MCP servers excluded.#{@reset}")
        IO.puts("  #{@dim}Exclude one with: /mcp exclude <name>#{@reset}")

      names ->
        IO.puts("  #{@bold}Excluded MCP servers#{@reset}")
        IO.puts("")
        Enum.each(names, fn n -> IO.puts("  #{@dim}·#{@reset} #{n}") end)
    end

    IO.puts("")
    session_id
  end

  # Add a name to the persistent deny list in ~/.osa/settings.json. Honoured for
  # every source, so this kills one noisy server without disabling anything else.
  defp mcp_exclude(name, session_id) do
    sanitized = MCP.Config.sanitize_name(name)
    current = MCP.Config.exclusions() |> Enum.sort()
    updated = Enum.sort(Enum.uniq([sanitized | current]))

    IO.puts("")

    case OptimalSystemAgent.Settings.set_user("mcp_exclude", updated) do
      :ok ->
        IO.puts("  #{@green}✓#{@reset} Excluded #{@cyan}#{sanitized}#{@reset}")
        IO.puts("  #{@dim}It will not load from any source. Restart or /mcp reload.#{@reset}")
        mcp_safe_reload()

      other ->
        IO.puts("  #{@red}✗#{@reset} Could not write settings: #{inspect(other)}")
    end

    IO.puts("")
    session_id
  end

  defp mcp_unexclude(name, session_id) do
    sanitized = MCP.Config.sanitize_name(name)
    updated = MCP.Config.exclusions() |> Enum.reject(&(&1 == sanitized)) |> Enum.sort()

    IO.puts("")

    case OptimalSystemAgent.Settings.set_user("mcp_exclude", updated) do
      :ok ->
        IO.puts("  #{@green}✓#{@reset} No longer excluding #{@cyan}#{sanitized}#{@reset}")
        mcp_safe_reload()

      other ->
        IO.puts("  #{@red}✗#{@reset} Could not write settings: #{inspect(other)}")
    end

    IO.puts("")
    session_id
  end

  defp mcp_status_display(status) do
    case status do
      s when s in [:ready, :connected, :running] ->
        {"#{@green}●#{@reset}", "connected"}

      s when s in [:initializing, :connecting, :starting] ->
        {"#{@yellow}◐#{@reset}", "connecting"}

      :disabled ->
        {"#{@dim}○#{@reset}", "disabled"}

      :down ->
        {"#{@red}○#{@reset}", "down"}

      other ->
        {"#{@dim}○#{@reset}", to_string(other || "unknown")}
    end
  end

  defp mcp_add(opts, session_id) do
    {flags, positional} = mcp_parse_opts(opts)
    scope = mcp_scope(flags[:scope])
    transport = flags[:transport]

    case positional do
      [name, target | rest] ->
        url_like =
          String.starts_with?(target, "http://") or String.starts_with?(target, "https://") or
            String.ends_with?(target, "/sse")

        if is_nil(transport) and url_like do
          IO.puts(
            "  #{@yellow}!#{@reset} #{@dim}#{target} looks like a URL; assuming remote transport. Pass -t stdio to override.#{@reset}"
          )
        end

        spec =
          cond do
            transport in ["http", "sse"] or (is_nil(transport) and url_like) ->
              %{"url" => target}
              |> then(fn m -> if transport, do: Map.put(m, "type", transport), else: m end)
              |> mcp_maybe_put("headers", mcp_header_map(flags[:headers]))

            true ->
              %{"command" => target, "args" => rest}
              |> mcp_maybe_put("env", mcp_env_map(flags[:env]))
          end

        case MCP.Config.add_server(name, spec, scope) do
          {:ok, path} ->
            IO.puts(
              "  #{@green}✓#{@reset} Added MCP server #{@cyan}#{name}#{@reset} #{@dim}(#{scope})#{@reset}"
            )

            IO.puts("  #{@dim}File modified: #{path}#{@reset}")
            mcp_safe_reload()

          {:error, reason} ->
            IO.puts("  #{@red}✗#{@reset} Failed to add #{name}: #{inspect(reason)}")
        end

      _ ->
        IO.puts(
          "  #{@dim}Usage: /mcp add <name> <command|url> [args...] [-s local|user|project] [-t stdio|sse|http] [-e K=V] [-H 'Header: value']#{@reset}"
        )
    end

    IO.puts("")
    session_id
  end

  defp mcp_remove(opts, session_id) do
    {flags, positional} = mcp_parse_opts(opts)

    case positional do
      [name | _] ->
        scopes =
          if flags[:scope], do: [mcp_scope(flags[:scope])], else: MCP.Config.find_scopes(name)

        case scopes do
          [] ->
            IO.puts("  #{@dim}No MCP server named #{name} found in any scope.#{@reset}")

          [scope] ->
            case MCP.Config.remove_server(name, scope) do
              {:ok, path} ->
                IO.puts(
                  "  #{@green}✓#{@reset} Removed #{@cyan}#{name}#{@reset} #{@dim}(#{scope})#{@reset}"
                )

                IO.puts("  #{@dim}File modified: #{path}#{@reset}")
                mcp_safe_reload()

              {:error, _} ->
                IO.puts("  #{@dim}#{name} not found in #{scope}.#{@reset}")
            end

          many ->
            IO.puts("  #{@yellow}!#{@reset} #{name} exists in multiple scopes. Specify one:")
            Enum.each(many, fn s -> IO.puts("  #{@dim}/mcp remove #{name} -s #{s}#{@reset}") end)
        end

      _ ->
        IO.puts("  #{@dim}Usage: /mcp remove <name> [-s local|user|project]#{@reset}")
    end

    IO.puts("")
    session_id
  end

  defp mcp_get(name, session_id) do
    sanitized = MCP.Config.sanitize_name(name)

    case Enum.find(MCP.Config.load_all(), fn s -> s.name == sanitized end) do
      nil ->
        IO.puts("  #{@dim}No MCP server named #{name}.#{@reset}")

      s ->
        IO.puts("")
        IO.puts("  #{@bold}#{s.name}#{@reset} #{@dim}(#{s.scope})#{@reset}")
        IO.puts("  #{@dim}transport:#{@reset} #{s.transport}")

        if s.command,
          do: IO.puts("  #{@dim}command:#{@reset} #{s.command} #{Enum.join(s.args, " ")}")

        if s.url, do: IO.puts("  #{@dim}url:#{@reset} #{s.url}")

        if map_size(s.env) > 0,
          do: IO.puts("  #{@dim}env:#{@reset} #{Enum.map_join(s.env, ", ", fn {k, _} -> k end)}")

        IO.puts("  #{@dim}Remove with: /mcp remove #{s.name} -s #{s.scope}#{@reset}")
    end

    IO.puts("")
    session_id
  end

  defp mcp_usage(session_id) do
    IO.puts("")
    IO.puts("  #{@bold}/mcp#{@reset} #{@dim}— manage MCP servers#{@reset}")

    IO.puts(
      "  #{@cyan}/mcp list#{@reset}                     #{@dim}Show servers and status#{@reset}"
    )

    IO.puts(
      "  #{@cyan}/mcp add <name> <cmd|url> ...#{@reset}  #{@dim}Add a server (-s scope -t transport -e K=V -H hdr)#{@reset}"
    )

    IO.puts("  #{@cyan}/mcp remove <name> [-s scope]#{@reset}  #{@dim}Remove a server#{@reset}")

    IO.puts(
      "  #{@cyan}/mcp get <name>#{@reset}               #{@dim}Show a server's config#{@reset}"
    )

    IO.puts(
      "  #{@cyan}/mcp exclude <name>#{@reset}            #{@dim}Never load this server, from any source#{@reset}"
    )

    IO.puts(
      "  #{@cyan}/mcp unexclude <name>#{@reset}          #{@dim}Remove a name from the deny list#{@reset}"
    )

    IO.puts("")
    session_id
  end

  # Flag parser: -s/--scope, -t/--transport, -e/--env (repeatable),
  # -H/--header (repeatable). Remaining tokens are positional.
  defp mcp_parse_opts(opts), do: mcp_parse_opts(opts, %{env: [], headers: []}, [])
  defp mcp_parse_opts([], flags, pos), do: {flags, Enum.reverse(pos)}

  defp mcp_parse_opts([f, v | rest], flags, pos) when f in ["-s", "--scope"],
    do: mcp_parse_opts(rest, Map.put(flags, :scope, v), pos)

  defp mcp_parse_opts([f, v | rest], flags, pos) when f in ["-t", "--transport"],
    do: mcp_parse_opts(rest, Map.put(flags, :transport, v), pos)

  defp mcp_parse_opts([f, v | rest], flags, pos) when f in ["-e", "--env"],
    do: mcp_parse_opts(rest, Map.update(flags, :env, [v], &(&1 ++ [v])), pos)

  defp mcp_parse_opts([f, v | rest], flags, pos) when f in ["-H", "--header"],
    do: mcp_parse_opts(rest, Map.update(flags, :headers, [v], &(&1 ++ [v])), pos)

  defp mcp_parse_opts([a | rest], flags, pos), do: mcp_parse_opts(rest, flags, [a | pos])

  defp mcp_scope(nil), do: :local
  defp mcp_scope("user"), do: :user
  defp mcp_scope("global"), do: :user
  defp mcp_scope("project"), do: :project
  defp mcp_scope(_), do: :local

  defp mcp_env_map(list) do
    Enum.reduce(list || [], %{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> Map.put(acc, k, v)
        _ -> acc
      end
    end)
  end

  defp mcp_header_map(list) do
    Enum.reduce(list || [], %{}, fn pair, acc ->
      case String.split(pair, ":", parts: 2) do
        [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
        _ -> acc
      end
    end)
  end

  defp mcp_maybe_put(map, _key, m) when map_size(m) == 0, do: map
  defp mcp_maybe_put(map, key, m), do: Map.put(map, key, m)

  defp mcp_safe_reload do
    MCP.Client.Manager.reload()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Project Init (seed AGENTS.md generation) ─────────────────────────

  def cmd_init(_args, session_id) do
    IO.puts("")
    path = Path.join(File.cwd!(), @init_guide)
    prompt = init_prompt()

    if File.exists?(path) do
      IO.puts("  #{@dim}#{@init_guide} already exists — a fresh scan will refresh it.#{@reset}")
    end

    if seed_session_prompt(session_id, prompt) do
      IO.puts(
        "  #{@green}✓#{@reset} Scanning project — OSA will write #{@bold}#{@init_guide}#{@reset}" <>
          " with the detected stack, conventions, and build commands."
      )
    else
      IO.puts("  #{@dim}Submit this prompt to generate #{@init_guide}:#{@reset}")
      IO.puts("")
      IO.puts("  #{prompt}")
    end

    IO.puts("")
    session_id
  end

  @doc "The canned prompt used by /init to generate OSA's own project guide."
  def init_prompt do
    """
    Analyze this project and create a concise #{@init_guide} guide at the repository \
    root that helps an AI coding agent work here effectively.

    Scan the working directory to detect the tech stack and languages, the \
    build/test/lint commands, the directory layout, key conventions, and any \
    important gotchas. Then write #{@init_guide} with these sections: Overview, \
    Tech Stack, Build & Test Commands, Project Layout, Conventions, and Gotchas. \
    Keep it factual and under ~200 lines. Do not invent details you cannot verify \
    from the codebase.
    """
    |> String.trim()
  end

  # Enqueue the seed prompt onto the session's live message queue so the agent
  # actually runs it. Returns true when a live queue accepted it, false when no
  # queue exists (e.g. HTTP one-shot) so the caller can surface the prompt text.
  defp seed_session_prompt(session_id, prompt) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, {:mq, session_id}) do
      [{_pid, _}] ->
        MessageQueue.enqueue(session_id, prompt)
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  # ── Copy last assistant reply ────────────────────────────────────────

  def cmd_copy(_args, session_id) do
    IO.puts("")

    case session_id |> Loop.get_messages() |> copy_payload() do
      {:ok, text} -> IO.puts(text)
      :empty -> IO.puts("  #{@dim}No assistant reply to copy yet.#{@reset}")
    end

    IO.puts("")
    session_id
  end

  @doc """
  The exact bytes `/copy` puts on stdout for a given message history.

  Separated from `cmd_copy/2` so what lands on the clipboard can be asserted
  on without standing up a live `Agent.Loop`.

  This is the sharpest of the plain-CLI render sites. The reply is model-chosen
  bytes, and the TUI copies captured stdout to the clipboard, so they go to the
  terminal AND onward into the operator's clipboard: an `ESC ] 52 ; c ;
  <base64> BEL` in a reply is a clipboard write the operator never authorised,
  and their next paste — possibly into a shell — is attacker-chosen. The reply
  is emitted rather than summarised, but never raw.

  `scrub_block/1` and not the line tier: a reply is a multi-line body, and its
  newlines are real content that must survive into the clipboard.
  """
  @spec copy_payload([map()]) :: {:ok, String.t()} | :empty
  def copy_payload(messages) when is_list(messages) do
    last =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> (m[:role] || m["role"]) in ["assistant", :assistant] end)

    content = if last, do: extract_text(last[:content] || last["content"]), else: nil

    if is_binary(content) and String.trim(content) != "" do
      {:ok, OptimalSystemAgent.CLI.Sanitize.scrub_block(content)}
    else
      :empty
    end
  end

  def copy_payload(_), do: :empty

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => t} when is_binary(t) -> t
      %{text: t} when is_binary(t) -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_text(_), do: ""

  # ── Workspace map ────────────────────────────────────────────────────

  @doc """
  `/map [path] [--refresh] [--depth N]` — print the workspace topology.

  Renders `OptimalSystemAgent.Workspace.Topology` at the terminal's real width,
  so the table sheds columns rather than wrapping on a narrow terminal. Served
  from the per-root cache unless `--refresh` is passed.
  """
  def cmd_map(args, session_id) do
    tokens = String.split(args || "", ~r/\s+/, trim: true)
    refresh? = "--refresh" in tokens or "-r" in tokens

    depth =
      case Enum.drop_while(tokens, &(&1 not in ["--depth", "-d"])) do
        [_, value | _] ->
          case Integer.parse(value) do
            {n, _} when n > 0 -> min(n, 6)
            _ -> 3
          end

        _ ->
          3
      end

    path = Enum.find(tokens, &(not String.starts_with?(&1, "-") and &1 not in [to_string(depth)]))

    cwd = OptimalSystemAgent.Workspace.Cwd.get()

    root =
      if path,
        do: Path.expand(path, cwd),
        else: OptimalSystemAgent.Workspace.Topology.workspace_root(cwd) || cwd

    IO.puts("")

    if File.dir?(root) do
      topo =
        OptimalSystemAgent.Workspace.Topology.get(root, refresh: refresh?, max_depth: depth)

      width =
        case :io.columns() do
          {:ok, cols} when is_integer(cols) and cols > 20 -> cols - 4
          _ -> 100
        end

      IO.puts(OptimalSystemAgent.Workspace.Topology.Render.report(topo, width: width))
    else
      IO.puts("  #{@red}Not a directory:#{@reset} #{root}")
    end

    IO.puts("")
    session_id
  end

  # ── Files in context ─────────────────────────────────────────────────

  def cmd_files(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Files in Context#{@reset}")
    IO.puts("")

    guide_loaded? =
      try do
        is_binary(ContextDiscovery.discover(File.cwd!()))
      rescue
        _ -> false
      end

    ref_files =
      session_id
      |> Loop.get_messages()
      |> Enum.filter(fn m -> (m[:role] || m["role"]) in ["user", :user] end)
      |> Enum.flat_map(fn m ->
        text = extract_text(m[:content] || m["content"])
        {_cleaned, refs} = ContextRefsParser.parse(text)
        for {:file, p, _range} <- refs, do: p
      end)
      |> Enum.uniq()

    if not guide_loaded? and ref_files == [] do
      IO.puts("  #{@dim}No files referenced in this session yet.#{@reset}")
      IO.puts("  #{@dim}Reference files with @file:path, or /init to scaffold a guide.#{@reset}")
    else
      if guide_loaded? do
        IO.puts("  #{@green}●#{@reset} #{@dim}project guide (auto-loaded)#{@reset}")
      end

      Enum.each(ref_files, fn p ->
        IO.puts("  #{@cyan}#{p}#{@reset} #{@dim}#{file_size_label(p)}#{@reset}")
      end)

      IO.puts("")
      IO.puts("  #{@dim}#{length(ref_files)} file reference(s)#{@reset}")
    end

    IO.puts("")
    session_id
  end

  defp file_size_label(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> "#{size} bytes"
      _ -> "not found"
    end
  end

  # ── Session rename / tag (persisted metadata) ────────────────────────

  def cmd_rename(args, session_id) do
    title = String.trim(args)
    IO.puts("")

    if title == "" do
      case SessionPersistence.get_metadata(session_id) do
        %{title: t} when is_binary(t) and t != "" ->
          IO.puts("  #{@bold}Session title:#{@reset} #{t}")

        _ ->
          IO.puts("  #{@dim}No title set. Usage: /rename <title>#{@reset}")
      end
    else
      persist_session_metadata(session_id, %{title: title})
      IO.puts("  #{@green}✓#{@reset} Session renamed to #{@bold}#{title}#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_tag(args, session_id) do
    tag = String.trim(args)
    IO.puts("")

    existing =
      case SessionPersistence.get_metadata(session_id) do
        %{tags: tags} when is_list(tags) -> tags
        _ -> []
      end

    cond do
      tag == "" and existing == [] ->
        IO.puts("  #{@dim}No tags. Usage: /tag <name>#{@reset}")

      tag == "" ->
        IO.puts("  #{@bold}Tags:#{@reset} #{Enum.join(existing, ", ")}")

      true ->
        updated = (existing ++ [tag]) |> Enum.uniq()
        persist_session_metadata(session_id, %{tags: updated})

        IO.puts(
          "  #{@green}✓#{@reset} Tagged #{@bold}#{tag}#{@reset} (#{Enum.join(updated, ", ")})"
        )
    end

    IO.puts("")
    session_id
  end

  defp persist_session_metadata(session_id, fields) do
    case SessionPersistence.update_metadata(session_id, fields) do
      :ok ->
        :ok

      {:error, :not_found} ->
        # No saved file yet — snapshot live messages first, then retry.
        SessionPersistence.auto_save(session_id)
        SessionPersistence.update_metadata(session_id, fields)

      other ->
        other
    end
  end

  # ── Sandbox backend switch ───────────────────────────────────────────

  @sandbox_backends ~w(host docker e2b miosa vercel)

  def cmd_sandbox(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "" ->
        show_sandbox_status()

      name ->
        switch_sandbox(String.downcase(name))
    end

    IO.puts("")
    session_id
  end

  defp show_sandbox_status do
    active = SandboxRouter.backend_name()

    IO.puts("  #{@bold}Sandbox Backends#{@reset}")
    IO.puts("")

    Enum.each(SandboxRouter.list_backends(), fn b ->
      marker = if b.display_name == active, do: "#{@green}*#{@reset}", else: " "

      avail =
        if b.available,
          do: "#{@green}available#{@reset}",
          else: "#{@dim}unavailable#{@reset}"

      IO.puts(
        "  #{marker} #{@cyan}#{String.pad_trailing(to_string(b.name), 10)}#{@reset}" <>
          " #{@dim}#{b.display_name}#{@reset} — #{avail}"
      )
    end)

    IO.puts("")
    IO.puts("  #{@dim}Active: #{active} · mode: #{SandboxRouter.mode()}#{@reset}")
    IO.puts("  #{@dim}Usage: /sandbox <#{Enum.join(@sandbox_backends, "|")}>#{@reset}")
  end

  defp switch_sandbox(name) do
    if name in @sandbox_backends do
      backend = String.to_existing_atom(name)
      Application.put_env(:optimal_system_agent, :sandbox_backend, backend)
      persist_sandbox_backend(name)
      IO.puts("  #{@green}✓#{@reset} Sandbox backend set to #{@bold}#{name}#{@reset}")
    else
      IO.puts("  #{@yellow}error: unknown backend '#{name}'#{@reset}")
      IO.puts("  #{@dim}Valid: #{Enum.join(@sandbox_backends, ", ")}#{@reset}")
    end
  end

  defp persist_sandbox_backend(backend) do
    path = sandbox_config_path()

    # Degrading an unreadable config.json to `%{}` here would rewrite the file
    # containing only "backend", discarding provider selection, API keys and
    # every other setting stored alongside it.
    case OptimalSystemAgent.System.JsonStore.read_map_for_write(path) do
      {:error, :corrupt} ->
        IO.puts(
          "  #{@yellow}error: #{OptimalSystemAgent.System.JsonStore.corrupt_message("sandbox backend", path)}#{@reset}"
        )

        {:error, :corrupt}

      {:ok, existing} ->
        File.mkdir_p!(Path.dirname(path))

        OptimalSystemAgent.System.AtomicFile.write!(
          path,
          Jason.encode!(Map.put(existing, "backend", backend), pretty: true)
        )

        :ok
    end
  rescue
    _ -> :ok
  end

  defp sandbox_config_path do
    Application.get_env(
      :optimal_system_agent,
      :sandbox_config_file,
      Path.expand("~/.osa/sandbox.json")
    )
  end
end
