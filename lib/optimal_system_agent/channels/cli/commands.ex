defmodule OptimalSystemAgent.Channels.CLI.Commands do
  @moduledoc """
  Slash command registry and dispatch for the CLI REPL.

  Commands are registered as `{handler_fn, description}` pairs in a static map.
  Dispatch parses the command name and arguments, routes to the handler, and
  returns the (possibly new) session_id.
  """

  require Logger

  alias OptimalSystemAgent.Agent.{Compactor, Loop, Tasks}
  alias OptimalSystemAgent.Budget
  alias OptimalSystemAgent.Channels.CLI.{Renderer, Session, TaskDisplay}
  alias OptimalSystemAgent.Memory
  alias OptimalSystemAgent.Tools.Registry, as: ToolsRegistry

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @yellow IO.ANSI.yellow()
  @green IO.ANSI.green()
  @red IO.ANSI.red()

  @commands %{
    "help"      => {"Show available commands", :cmd_help},
    "clear"     => {"Clear conversation and start fresh session", :cmd_clear},
    "new"       => {"Start a new session (alias for /clear)", :cmd_clear},
    "compact"   => {"Force context compaction", :cmd_compact},
    "model"     => {"Show or switch the current model", :cmd_model},
    "status"    => {"Show session status", :cmd_status},
    "cost"      => {"Show cost breakdown", :cmd_cost},
    "context"   => {"Show context window usage", :cmd_context},
    "memory"    => {"Show memory entries", :cmd_memory},
    "tools"     => {"List available tools", :cmd_tools},
    "skills"    => {"List available skills", :cmd_skills},
    "agents"    => {"List available agent roles", :cmd_agents},
    "sessions"  => {"List recent sessions", :cmd_sessions},
    "tasks"     => {"Show current tasks", :cmd_tasks},
    "plan"      => {"Toggle plan mode", :cmd_plan},
    "doctor"    => {"Run health check", :cmd_doctor},
    "export"    => {"Export conversation as markdown", :cmd_export},
    "version"   => {"Show version info", :cmd_version},
    "coordinator" => {"Toggle coordinator mode (delegation only)", :cmd_coordinator},
    "effort"    => {"Set thinking effort level (low/medium/high/max)", :cmd_effort},
    "fast"      => {"Toggle fast mode (low effort)", :cmd_fast},
    "permissions" => {"View and manage permission rules", :cmd_permissions},
    "hooks"     => {"View registered hooks", :cmd_hooks},
    "metrics"   => {"Show telemetry metrics", :cmd_metrics},
    "login"     => {"Sign in with a provider (e.g. /login anthropic)", :cmd_login},
    "logout"    => {"Disconnect OAuth session for a provider", :cmd_logout},
    "exit"      => {"Exit OSA", :cmd_exit}
  }

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
        before_tokens = state[:estimated_tokens] || 0

        case Loop.compact(session_id) do
          :ok ->
            case Loop.get_state(session_id) do
              {:ok, after_state} ->
                after_tokens = after_state[:estimated_tokens] || 0
                saved = before_tokens - after_tokens
                pct = if before_tokens > 0, do: round(saved / before_tokens * 100), else: 0
                IO.puts("  #{@green}#{@reset} Compacted: #{format_tokens(before_tokens)} -> #{format_tokens(after_tokens)} (#{pct}% reduction)")

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
        iter = state[:iteration_count] || state[:iteration] || 0
        tokens = state[:estimated_tokens] || 0
        max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
        pct = if max_tokens > 0, do: round(tokens / max_tokens * 100), else: 0

        IO.puts("  #{@dim}Iteration:#{@reset} #{iter}")
        IO.puts("  #{@dim}Context:#{@reset}   #{pct}% (#{format_tokens(tokens)} / #{format_tokens(max_tokens)})")

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
      IO.puts("  #{@dim}└─ Total:#{@reset}    $#{:erlang.float_to_binary(total / 1, decimals: 4)}")
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
        total_tokens = state[:estimated_tokens] || 0
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
        IO.puts("  #{@dim}│#{bar_color}#{String.duplicate("█", filled)}#{@dim}#{String.duplicate("░", empty)}#{@reset}#{@dim}│#{@reset}")
        IO.puts("  #{@dim}└#{String.duplicate("─", bar_width)}┘#{@reset}")
        IO.puts("")
        IO.puts("  #{@dim}System prompt:#{@reset}  #{pad_num(static_tokens)} tokens (#{round(static_tokens / max(max_tokens, 1) * 100)}%)")
        IO.puts("  #{@dim}Conversation:#{@reset}   #{pad_num(conversation_tokens)} tokens (#{round(conversation_tokens / max(max_tokens, 1) * 100)}%)")
        IO.puts("  #{@dim}Available:#{@reset}      #{pad_num(available)} tokens (#{round(available / max(max_tokens, 1) * 100)}%)")
        IO.puts("  #{@dim}Total:#{@reset}          #{pad_num(max_tokens)} tokens")

        # Compaction stats
        try do
          comp_stats = Compactor.stats()
          if comp_stats[:compaction_count] && comp_stats[:compaction_count] > 0 do
            IO.puts("")
            IO.puts("  #{@dim}Compressions:#{@reset}   #{comp_stats[:compaction_count]}")
            IO.puts("  #{@dim}Tokens saved:#{@reset}   #{format_tokens(comp_stats[:tokens_saved] || 0)}")
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
      stats = Memory.stats()
      total = stats[:total] || stats[:count] || 0
      IO.puts("  #{@dim}Entries:#{@reset} #{total}")

      case Memory.Store.recent(10) do
        entries when is_list(entries) and length(entries) > 0 ->
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

  def cmd_agents(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Agent Roles#{@reset}")
    IO.puts("")

    try do
      agents = OptimalSystemAgent.Agents.Registry.list()

      if is_list(agents) and length(agents) > 0 do
        Enum.each(agents, fn agent ->
          name = agent[:name] || agent[:role] || "?"
          tier = agent[:tier] || :specialist
          desc = agent[:description] || ""
          truncated = String.slice(desc, 0, 45)
          tier_label = "#{tier}"
          padded = String.pad_trailing(name, 18)
          IO.puts("  #{@cyan}#{padded}#{@reset} #{@dim}[#{tier_label}]#{@reset} #{@dim}#{truncated}#{@reset}")
        end)

        IO.puts("")
        IO.puts("  #{@dim}#{length(agents)} agents available#{@reset}")
      else
        IO.puts("  #{@dim}No agent roles defined#{@reset}")
      end
    rescue
      _ ->
        IO.puts("  #{@dim}Agent registry not available#{@reset}")
    end

    IO.puts("")
    session_id
  end

  def cmd_sessions(_args, session_id) do
    IO.puts("")
    IO.puts("  #{@bold}Active Sessions#{@reset}")
    IO.puts("")

    try do
      sessions =
        Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])

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

    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] ->
        try do
          state = :sys.get_state(pid)
          current = state.plan_mode || false

          if current do
            GenServer.call(pid, {:set_plan_mode, false})
            IO.puts("  #{@green}#{@reset} Plan mode #{@bold}disabled#{@reset}")
          else
            GenServer.call(pid, {:set_plan_mode, true})
            IO.puts("  #{@green}#{@reset} Plan mode #{@bold}enabled#{@reset} — agent will propose a plan before acting")
          end
        rescue
          _ ->
            IO.puts("  #{@yellow}error: could not toggle plan mode#{@reset}")
        end

      _ ->
        IO.puts("  #{@yellow}error: session not found#{@reset}")
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
    version = Application.spec(:optimal_system_agent, :vsn) |> to_string()
    try do
      {hash, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true)
      IO.puts("\n  #{@bold}OSA#{@reset} #{@dim}v#{version} (#{String.trim(hash)})#{@reset}\n")
    rescue
      _ ->
        IO.puts("\n  #{@bold}OSA#{@reset} #{@dim}v#{version}#{@reset}\n")
    end

    session_id
  end

  def cmd_export(args, session_id) do
    IO.puts("")

    export_dir = Path.expand("~/.osa/exports")
    File.mkdir_p!(export_dir)

    target_id = case String.trim(args) do
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
          IO.puts("  #{@green}✓#{@reset} Effort set to #{@bold}#{level}#{@reset} — #{config.description}")
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

    if Effort.fast_mode?() do
      IO.puts("  #{@green}✓#{@reset} Fast mode #{@bold}enabled#{@reset} — low effort, quick responses")
    else
      IO.puts("  #{@green}✓#{@reset} Fast mode #{@bold}disabled#{@reset} — back to #{Effort.current()} effort")
    end

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
            IO.puts("  #{@green}✓#{@reset} Coordinator mode #{@bold}disabled#{@reset} — full tool access restored")
            IO.puts("")
            new_id
          else
            # Restart session in coordinator mode
            Session.stop_session(session_id)
            new_id = "cli_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"

            {:ok, _pid} =
              DynamicSupervisor.start_child(
                OptimalSystemAgent.SessionSupervisor,
                {OptimalSystemAgent.Agent.Loop, session_id: new_id, channel: :cli, coordinator: true}
              )

            Session.register_permission_hook(new_id)
            IO.puts("  #{@green}✓#{@reset} Coordinator mode #{@bold}enabled#{@reset} — tools restricted to delegation and messaging")
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
          status = if configured, do: "#{@green}✓ connected#{@reset}", else: "#{@dim}not connected#{@reset}"
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
        connected = Enum.filter(@oauth_providers, fn {slug, _} -> check_oauth_configured(slug) end)

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

  # ── Helpers ──────────────────────────────────────────────────────────

  defp format_tokens(0), do: "0"
  defp format_tokens(n) when n < 1_000, do: "#{n}"
  defp format_tokens(n), do: "#{Float.round(n / 1_000, 1)}k"

  defp pad_num(n), do: String.pad_leading(format_tokens(n), 8)

  defp get_model_name(:anthropic) do
    Application.get_env(:optimal_system_agent, :anthropic_model, "claude-sonnet-4-6")
  end

  defp get_model_name(:ollama) do
    Application.get_env(:optimal_system_agent, :ollama_model, "detecting...")
  end

  defp get_model_name(:openai) do
    Application.get_env(:optimal_system_agent, :openai_model, "gpt-4o")
  end

  defp get_model_name(provider) do
    key = :"#{provider}_model"
    Application.get_env(:optimal_system_agent, key, to_string(provider))
  end

  # ── Permission Management ────────────────────────────────────────────

  def cmd_permissions(args, session_id) do
    IO.puts("")

    case String.trim(args) do
      "" ->
        rules = OptimalSystemAgent.Permissions.list_rules()

        if map_size(rules) == 0 do
          IO.puts("  #{@dim}No permission rules configured.#{@reset}")
          IO.puts("  #{@dim}Rules are saved when you choose 'Allow always' on a permission prompt.#{@reset}")
        else
          IO.puts("  #{@bold}Permission Rules#{@reset}")
          IO.puts("")
          Enum.each(rules, fn {tool, action} ->
            icon = if action == "allow", do: "#{IO.ANSI.green()}✓#{@reset}", else: "#{IO.ANSI.red()}✗#{@reset}"
            IO.puts("  #{icon} #{tool} → #{action}")
          end)
        end

        IO.puts("")
        IO.puts("  #{@dim}Usage: /permissions remove <tool_name>#{@reset}")

      "remove " <> tool_name ->
        OptimalSystemAgent.Permissions.remove_rule(String.trim(tool_name))
        IO.puts("  #{IO.ANSI.green()}✓#{@reset} Removed rule for #{String.trim(tool_name)}")

      _ ->
        IO.puts("  #{@dim}Usage: /permissions [remove <tool>]#{@reset}")
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
          IO.puts("  #{@cyan}#{String.pad_trailing(to_string(name), 20)}#{@reset}" <>
            " #{stats.count} calls" <>
            " #{@dim}avg #{stats.avg_ms}ms#{@reset}" <>
            " #{@dim}p99 #{stats.p99_ms}ms#{@reset}" <>
            " #{@dim}#{stats.success}✓ #{stats.fail}✗#{@reset}")
        end)
        IO.puts("")
      end

      if map_size(snapshot.providers) > 0 do
        IO.puts("  #{@bold}Providers#{@reset}")
        Enum.each(snapshot.providers, fn {name, stats} ->
          IO.puts("  #{@cyan}#{String.pad_trailing(to_string(name), 20)}#{@reset}" <>
            " #{stats.count} calls" <>
            " #{@dim}avg #{stats.avg_ms}ms#{@reset}" <>
            " #{@dim}p99 #{stats.p99_ms}ms#{@reset}")
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
end
