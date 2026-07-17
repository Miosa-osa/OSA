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
  alias OptimalSystemAgent.Tools.Registry, as: ToolsRegistry

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
    "context" => {"Show context window usage", :cmd_context},
    "memory" => {"Show memory entries", :cmd_memory},
    "tools" => {"List available tools", :cmd_tools},
    "skills" => {"List available skills", :cmd_skills},
    "agents" => {"Runtime agent dashboard — live subagent runs and roles", :cmd_agents},
    "bg" => {"List background work — subagent runs and background commands", :cmd_bg},
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
    "login" => {"Sign in with a provider (e.g. /login anthropic)", :cmd_login},
    "logout" => {"Disconnect OAuth session for a provider", :cmd_logout},
    "setup" => {"Re-run the setup wizard", :cmd_setup},
    "channels" => {"Show connected messaging channels", :cmd_channels},
    "resume" => {"Resume a previous session", :cmd_resume},
    "persona" => {"Show or switch persona preset", :cmd_persona},
    "mcp" => {"List MCP servers and connection status", :cmd_mcp},
    "init" => {"Scan the project and write an AGENTS.md guide", :cmd_init},
    "copy" => {"Copy the last assistant reply", :cmd_copy},
    "files" => {"List files currently in context", :cmd_files},
    "rename" => {"Rename the current session", :cmd_rename},
    "tag" => {"Tag the current session for search", :cmd_tag},
    "sandbox" => {"Show or switch the sandbox backend", :cmd_sandbox},
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

  def cmd_compact(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@dim}Compacting context...#{@reset}")

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

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: compaction failed#{@reset}\n")
      session_id
  end

  def cmd_model(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "" ->
        provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
        model = get_model_name(provider)
        max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)

        IO.puts("  #{@bold}Current Model#{@reset}")
        IO.puts("  #{@dim}Provider:#{@reset}  #{provider}")
        IO.puts("  #{@dim}Model:#{@reset}     #{model}")
        IO.puts("  #{@dim}Context:#{@reset}   #{format_tokens(max_tokens)} tokens")

      model_name ->
        IO.puts("  #{@dim}Switching model...#{@reset}")

        case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
          [{pid, _}] ->
            provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)
            GenServer.call(pid, {:swap_provider, provider, model_name})
            IO.puts("  #{@green}#{@reset} Switched to #{model_name}")

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
    model = get_model_name(provider)
    tool_count = length(ToolsRegistry.list_tools_direct())
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)

    IO.puts("  #{@dim}Session:#{@reset}   #{session_id}")
    IO.puts("  #{@dim}Uptime:#{@reset}    #{Renderer.format_elapsed(uptime_ms)}")
    IO.puts("  #{@dim}Provider:#{@reset}  #{provider}")
    IO.puts("  #{@dim}Model:#{@reset}     #{model}")
    IO.puts("  #{@dim}Tools:#{@reset}     #{tool_count} loaded")

    case Loop.get_state(session_id) do
      {:ok, state} ->
        iter = state[:iteration] || state[:iteration_count] || 0
        tokens = state[:tokens_used] || state[:estimated_tokens] || 0
        max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
        pct = if max_tokens > 0, do: round(tokens / max_tokens * 100), else: 0

        IO.puts("  #{@dim}Iteration:#{@reset} #{iter}")

        IO.puts(
          "  #{@dim}Context:#{@reset}   #{pct}% (#{format_tokens(tokens)} / #{format_tokens(max_tokens)})"
        )

      _ ->
        :ok
    end

    try do
      budget = Budget.get_status()
      cost = budget[:total_cost_usd] || 0
      IO.puts("  #{@dim}Cost:#{@reset}      $#{:erlang.float_to_binary(cost / 1, decimals: 4)}")
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
      budget = Budget.get_status()
      total = budget[:total_cost_usd] || 0
      input_tokens = budget[:input_tokens] || budget[:total_input_tokens] || 0
      output_tokens = budget[:output_tokens] || budget[:total_output_tokens] || 0
      sessions = budget[:sessions] || 0

      IO.puts("  #{@dim}├─ Input:#{@reset}    #{format_tokens(input_tokens)} tokens")
      IO.puts("  #{@dim}├─ Output:#{@reset}   #{format_tokens(output_tokens)} tokens")
      IO.puts("  #{@dim}├─ Sessions:#{@reset} #{sessions}")

      IO.puts(
        "  #{@dim}└─ Total:#{@reset}    $#{:erlang.float_to_binary(total / 1, decimals: 4)}"
      )
    rescue
      _ ->
        IO.puts("  #{@dim}  No cost data available#{@reset}")
    end

    IO.puts("")
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

  def cmd_memory(_args, session_id) do
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

  def cmd_skills(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Available Skills#{@reset}")
    IO.puts("")

    skills = ToolsRegistry.list_skills()

    if length(skills) > 0 do
      Enum.each(skills, fn skill ->
        name = skill[:name] || "?"
        desc = skill[:description] || ""
        truncated = String.slice(desc, 0, 55)
        padded = String.pad_trailing(name, 22)
        IO.puts("  #{@cyan}#{padded}#{@reset} #{@dim}#{truncated}#{@reset}")
      end)

      IO.puts("")
      IO.puts("  #{@dim}#{length(skills)} skills available#{@reset}")
    else
      IO.puts("  #{@dim}No skills loaded#{@reset}")
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
          IO.puts("  #{marker} #{@dim}#{sid}#{@reset}")
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

  def cmd_doctor(_args, session_id) do
    IO.puts("")
    OptimalSystemAgent.CLI.Doctor.run()
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
        case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
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
    IO.puts("  #{@bold}What's New#{@reset} #{@dim}(OSA v#{ReleaseNotes.current_version()})#{@reset}")
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
      "" ->
        current = Effort.current()
        config = Effort.get(current)
        IO.puts("  #{@bold}Effort Level: #{current}#{@reset}")
        IO.puts("  #{@dim}#{config.description}#{@reset}")
        IO.puts("")
        IO.puts("  #{@dim}Thinking budget:#{@reset} #{config.thinking_budget} tokens")
        IO.puts("  #{@dim}Max iterations:#{@reset}  #{config.max_iterations}")
        IO.puts("  #{@dim}Temperature:#{@reset}     #{config.temperature}")
        IO.puts("")
        IO.puts("  #{@dim}Usage: /effort low|medium|high|max#{@reset}")

      level_str ->
        level = String.to_existing_atom(level_str)

        if level in Effort.levels() do
          Effort.set(level)
          config = Effort.get(level)

          IO.puts(
            "  #{@green}✓#{@reset} Effort set to #{@bold}#{level}#{@reset} — #{config.description}"
          )
        else
          IO.puts("  #{@yellow}error: invalid level '#{level_str}'#{@reset}")
          IO.puts("  #{@dim}Valid levels: low, medium, high, max#{@reset}")
        end
    end

    IO.puts("")
    session_id
  rescue
    _ ->
      IO.puts("  #{@yellow}error: invalid level#{@reset}")
      IO.puts("  #{@dim}Valid levels: low, medium, high, max#{@reset}\n")
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

  @oauth_providers %{
    "anthropic" => %{name: "Anthropic", module: OptimalSystemAgent.Auth.OAuth}
    # Future: "openai" => %{name: "OpenAI", module: OptimalSystemAgent.Auth.OpenAIOAuth}
  }

  def cmd_login(args, session_id) do
    provider_slug = String.trim(args) |> String.downcase()

    cond do
      provider_slug == "" ->
        # No provider specified — show available OAuth providers
        IO.puts("")
        IO.puts("  #{@bold}Sign in with a provider#{@reset}")
        IO.puts("")

        for {slug, meta} <- @oauth_providers do
          configured = check_oauth_configured(slug)

          status =
            if configured,
              do: "#{@green}✓ connected#{@reset}",
              else: "#{@dim}not connected#{@reset}"

          IO.puts("  #{@cyan}/login #{slug}#{@reset}  #{@dim}—#{@reset}  #{meta.name}  #{status}")
        end

        IO.puts("")
        IO.puts("#{@dim}  Or set an API key directly: ANTHROPIC_API_KEY=sk-...#{@reset}\n")

      Map.has_key?(@oauth_providers, provider_slug) ->
        meta = @oauth_providers[provider_slug]

        if check_oauth_configured(provider_slug) do
          IO.puts("#{@green}  ✓ Already signed in with #{meta.name}#{@reset}")
          IO.puts("#{@dim}  Use /logout #{provider_slug} to disconnect#{@reset}\n")
        else
          start_oauth_flow(meta.name)
        end

      true ->
        IO.puts("#{@yellow}  Unknown provider: #{provider_slug}#{@reset}")
        available = Map.keys(@oauth_providers) |> Enum.join(", ")
        IO.puts("#{@dim}  Providers with OAuth: #{available}#{@reset}\n")
    end

    session_id
  end

  def cmd_logout(args, session_id) do
    provider_slug = String.trim(args) |> String.downcase()

    cond do
      provider_slug == "" ->
        # Show what's connected
        connected =
          Enum.filter(@oauth_providers, fn {slug, _} -> check_oauth_configured(slug) end)

        if connected == [] do
          IO.puts("#{@dim}  No OAuth sessions active#{@reset}\n")
        else
          for {slug, meta} <- connected do
            IO.puts("#{@dim}  /logout #{slug}#{@reset}  #{@dim}—#{@reset}  #{meta.name}")
          end

          IO.puts("")
        end

      Map.has_key?(@oauth_providers, provider_slug) ->
        meta = @oauth_providers[provider_slug]

        if check_oauth_configured(provider_slug) do
          OptimalSystemAgent.Auth.OAuth.clear_credentials()
          IO.puts("#{@dim}  Disconnected from #{meta.name}#{@reset}\n")
        else
          IO.puts("#{@dim}  Not connected to #{meta.name}#{@reset}\n")
        end

      true ->
        IO.puts("#{@yellow}  Unknown provider: #{provider_slug}#{@reset}\n")
    end

    session_id
  end

  defp check_oauth_configured(_slug) do
    # Currently all OAuth providers use the same credential store
    OptimalSystemAgent.Auth.OAuth.oauth_configured?()
  end

  defp start_oauth_flow(provider_name) do
    alias OptimalSystemAgent.Auth.OAuth

    port = Application.get_env(:optimal_system_agent, :http_port, 9089)
    redirect_uri = "http://127.0.0.1:#{port}/onboarding/oauth/callback"
    {authorize_url, code_verifier, state} = OAuth.authorize_url(redirect_uri)

    try do
      :ets.new(:oauth_state, [:set, :public, :named_table])
    rescue
      ArgumentError -> :oauth_state
    end

    :ets.insert(:oauth_state, {:pkce, code_verifier, state, redirect_uri})

    IO.puts("")
    IO.puts("#{@bold}  Sign in with #{provider_name}#{@reset}")
    IO.puts("#{@dim}  Opening your browser...#{@reset}")
    IO.puts("")

    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [authorize_url])
      {:unix, _} -> System.cmd("xdg-open", [authorize_url])
      {:win32, _} -> System.cmd("cmd", ["/c", "start", authorize_url])
    end

    IO.puts("#{@dim}  If the browser didn't open, visit:#{@reset}")
    IO.puts("#{@cyan}  #{authorize_url}#{@reset}")
    IO.puts("")
    IO.puts("#{@dim}  Waiting for authorization...#{@reset}")

    poll_oauth_status(30)
  end

  defp poll_oauth_status(0) do
    IO.puts("#{@yellow}  Timed out waiting for authorization#{@reset}\n")
  end

  defp poll_oauth_status(remaining) do
    Process.sleep(2_000)

    case OptimalSystemAgent.Auth.OAuth.oauth_configured?() do
      true ->
        IO.puts("#{@green}  ✓ Connected to Anthropic#{@reset}\n")

      false ->
        poll_oauth_status(remaining - 1)
    end
  end

  def cmd_setup(_args, session_id) do
    IO.puts("")
    OptimalSystemAgent.CLI.Setup.run()
    IO.puts("")
    session_id
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

            IO.puts("  #{@cyan}#{id}#{@reset}  #{@dim}#{date_str}#{@reset}")

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

  def cmd_mcp(_args, session_id) do
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
              " #{@dim}#{s[:transport]} · #{label} · #{tools} tools#{@reset}"
          )
        end)

        IO.puts("")
        IO.puts("  #{@dim}#{length(running)} server(s)#{@reset}")

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
                " #{@dim}#{s.transport} · not started#{@reset}"
            )
          end)

          IO.puts("")
          IO.puts("  #{@dim}#{length(configured)} server(s) configured (manager offline)#{@reset}")
        end
    end

    IO.puts("")
    session_id
  end

  defp mcp_status_display(status) do
    case status do
      s when s in [:ready, :connected, :running] -> {"#{@green}●#{@reset}", "connected"}
      s when s in [:initializing, :connecting, :starting] -> {"#{@yellow}◐#{@reset}", "connecting"}
      :disabled -> {"#{@dim}○#{@reset}", "disabled"}
      :down -> {"#{@red}○#{@reset}", "down"}
      other -> {"#{@dim}○#{@reset}", to_string(other || "unknown")}
    end
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

    last =
      session_id
      |> Loop.get_messages()
      |> Enum.reverse()
      |> Enum.find(fn m -> (m[:role] || m["role"]) in ["assistant", :assistant] end)

    content = if last, do: extract_text(last[:content] || last["content"]), else: nil

    if is_binary(content) and String.trim(content) != "" do
      # The TUI copies captured stdout to the clipboard, so emit the raw reply.
      IO.puts(content)
    else
      IO.puts("  #{@dim}No assistant reply to copy yet.#{@reset}")
    end

    IO.puts("")
    session_id
  end

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
        IO.puts("  #{@green}✓#{@reset} Tagged #{@bold}#{tag}#{@reset} (#{Enum.join(updated, ", ")})")
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

    existing =
      case File.read(path) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, m} when is_map(m) -> m
            _ -> %{}
          end

        _ ->
          %{}
      end

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Map.put(existing, "backend", backend), pretty: true))
    :ok
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
