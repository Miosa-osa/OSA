defmodule OptimalSystemAgent.Channels.CLI do
  @moduledoc """
  Interactive CLI REPL — clean, colored, responsive.
  Supports streaming responses, animated spinner, tool feedback,
  markdown rendering, and signal classification indicators.
  Start with: mix osa.chat
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.CLI.Markdown
  alias OptimalSystemAgent.Commands
  alias OptimalSystemAgent.Events.Bus

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @yellow IO.ANSI.yellow()
  @white IO.ANSI.white()

  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  def start do
    # Clear screen and print banner
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    print_banner()

    session_id = "cli_#{:rand.uniform(999_999)}"
    {:ok, _pid} = Loop.start_link(session_id: session_id, channel: :cli)

    # Register event handlers for CLI feedback
    register_tool_handler()
    register_signal_handler()
    register_orchestrator_handler()

    IO.puts("")
    loop(session_id)
  end

  defp loop(session_id) do
    prompt = "#{@bold}#{@cyan}> #{@reset}"

    case IO.gets(prompt) do
      :eof ->
        print_goodbye()

      "exit\n" ->
        print_goodbye()

      "quit\n" ->
        print_goodbye()

      "clear\n" ->
        IO.write(IO.ANSI.clear() <> IO.ANSI.home())
        print_banner()
        IO.puts("")
        loop(session_id)

      input ->
        input = String.trim(input)

        next_session =
          if input == "" do
            session_id
          else
            process_input(input, session_id)
          end

        loop(next_session)
    end
  end

  defp process_input(input, session_id) do
    if String.starts_with?(input, "/") do
      cmd = String.trim_leading(input, "/")
      handle_command(cmd, session_id)
    else
      send_to_agent(input, session_id)
      session_id
    end
  end

  # ── Event Handlers ──────────────────────────────────────────────────

  defp register_tool_handler do
    Bus.register_handler(:tool_call, fn payload ->
      case payload do
        %{name: name, phase: :start} ->
          IO.write("#{@dim}  ⚙ #{name}...#{@reset}")

        %{name: name, phase: :end, duration_ms: ms} ->
          clear_line()
          IO.puts("#{@dim}  ⚙ #{name} (#{ms}ms)#{@reset}")

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  defp register_signal_handler do
    # Capture the latest signal from agent_response events into an ETS table
    # so the CLI can display it after the synchronous call returns.
    table =
      try do
        :ets.new(:cli_signal_cache, [:set, :public, :named_table])
      rescue
        ArgumentError -> :cli_signal_cache
      end

    Bus.register_handler(:agent_response, fn payload ->
      case payload do
        %{session_id: sid, signal: signal} when not is_nil(signal) ->
          try do
            :ets.insert(table, {sid, signal})
          rescue
            _ -> :ok
          end

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  defp register_orchestrator_handler do
    Bus.register_handler(:system_event, fn payload ->
      case payload do
        %{event: :orchestrator_task_started, task_id: task_id} ->
          clear_line()
          IO.puts("#{@bold}#{@cyan}  ▶ Spawning agents...#{@reset}")
          # Subscribe CLI process to progress updates
          try do
            :ets.insert(:cli_signal_cache, {:active_task, task_id})
          rescue
            _ -> :ok
          end

        %{event: :orchestrator_agents_spawning, agent_count: count} ->
          clear_line()
          IO.puts("#{@cyan}  ▶ Deploying #{count} agent#{if count > 1, do: "s", else: ""}#{@reset}")

        %{event: :orchestrator_agent_started, agent_name: name, role: role} ->
          role_str = if role, do: " (#{role})", else: ""
          IO.puts("#{@dim}  ├─ #{name}#{role_str} started#{@reset}")

        %{event: :orchestrator_agent_progress, agent_name: name, current_action: action}
          when is_binary(action) and action != "" ->
          clear_line()
          IO.write("#{@dim}  │  #{name}: #{String.slice(action, 0, 60)}#{@reset}")

        %{event: :orchestrator_agent_completed, agent_name: name} ->
          clear_line()
          IO.puts("#{@dim}  ├─ #{name} done#{@reset}")

        %{event: :orchestrator_synthesizing} ->
          clear_line()
          IO.puts("#{@cyan}  ▶ Synthesizing results...#{@reset}")

        %{event: :orchestrator_task_completed} ->
          clear_line()
          IO.puts("#{@cyan}  ▶ All agents completed#{@reset}")

        %{event: :orchestrator_task_failed, reason: reason} ->
          clear_line()
          IO.puts("#{@yellow}  ▶ Orchestration failed: #{reason}#{@reset}")

        %{event: :swarm_started, swarm_id: id} ->
          clear_line()
          IO.puts("#{@bold}#{@cyan}  ◆ Swarm #{String.slice(id, 0, 8)}... launched#{@reset}")

        %{event: :swarm_completed, swarm_id: id} ->
          clear_line()
          IO.puts("#{@cyan}  ◆ Swarm #{String.slice(id, 0, 8)}... completed#{@reset}")

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  defp get_cached_signal(session_id) do
    case :ets.lookup(:cli_signal_cache, session_id) do
      [{^session_id, signal}] ->
        :ets.delete(:cli_signal_cache, session_id)
        signal

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # ── Command Handling ─────────────────────────────────────────────────

  # Returns the next session_id (may change on /new or /resume)
  defp handle_command(cmd, session_id) do
    case Commands.execute(cmd, session_id) do
      {:command, output} ->
        print_response(output)
        session_id

      {:prompt, expanded} ->
        IO.puts("#{@dim}  /#{String.split(cmd, " ") |> hd()}#{@reset}")
        send_to_agent(expanded, session_id)
        session_id

      {:action, action, output} ->
        print_response(output)
        handle_action(action, session_id)

      :unknown ->
        cmd_name = String.split(cmd, ~r/\s+/) |> hd()
        suggestion = suggest_command(cmd_name)

        IO.puts("#{@yellow}  error: unknown command '/#{cmd_name}'#{@reset}")
        if suggestion do
          IO.puts("#{@dim}  (Did you mean /#{suggestion}?)#{@reset}\n")
        else
          IO.puts("#{@dim}  Type /help to see available commands#{@reset}\n")
        end
        session_id
    end
  end

  # Returns new session_id
  defp handle_action(:new_session, old_session_id) do
    stop_session(old_session_id)

    new_session_id = "cli_#{:rand.uniform(999_999)}"
    {:ok, _pid} = Loop.start_link(session_id: new_session_id, channel: :cli)
    IO.puts("#{@dim}  session: #{new_session_id}#{@reset}\n")
    new_session_id
  end

  defp handle_action({:resume_session, target_id, _messages}, old_session_id) do
    stop_session(old_session_id)

    {:ok, _pid} = Loop.start_link(session_id: target_id, channel: :cli)
    IO.puts("#{@dim}  resumed: #{target_id}#{@reset}\n")
    target_id
  end

  defp handle_action(_, session_id), do: session_id

  defp stop_session(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      _ -> :ok
    end
  end

  # ── Agent Communication ─────────────────────────────────────────────

  defp send_to_agent(input, session_id) do
    spinner = start_spinner()

    case Loop.process_message(session_id, input) do
      {:ok, response} ->
        stop_spinner(spinner)

        # Check for signal metadata from the Bus event handler
        signal = get_cached_signal(session_id)
        maybe_show_signal(signal, session_id)

        print_response(response)

      {:error, reason} ->
        stop_spinner(spinner)
        IO.puts("#{@yellow}  error: #{reason}#{@reset}\n")
    end
  end

  # ── Spinner ─────────────────────────────────────────────────────────

  defp start_spinner do
    parent = self()

    spawn_link(fn ->
      spinner_loop(@spinner_frames, parent)
    end)
  end

  defp spinner_loop([], parent), do: spinner_loop(@spinner_frames, parent)

  defp spinner_loop([frame | rest], parent) do
    clear_line()
    IO.write("#{@dim}  #{frame} thinking...#{@reset}")

    receive do
      :stop -> :ok
    after
      80 ->
        if Process.alive?(parent) do
          spinner_loop(rest, parent)
        end
    end
  end

  defp stop_spinner(pid) do
    if Process.alive?(pid) do
      send(pid, :stop)
      # Give it a moment to exit cleanly
      Process.sleep(10)

      # Ensure process is dead (it's spawn_link'd so should die, but be safe)
      if Process.alive?(pid) do
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end
    end

    clear_line()
  end

  # ── Signal Classification Indicator ─────────────────────────────────

  defp maybe_show_signal(nil, _session_id), do: :ok

  defp maybe_show_signal(signal, _session_id) do
    mode = signal.mode |> to_string()
    genre = signal.genre |> to_string()
    weight = Float.round(signal.weight, 1)
    IO.puts("#{@dim}  #{mode} · #{genre} · w#{weight}#{@reset}")
  end

  # ── Banner ──────────────────────────────────────────────────────────

  defp print_banner do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
    model = get_model_name(provider)
    skill_count = length(OptimalSystemAgent.Skills.Registry.list_tools_direct())
    soul_status = if OptimalSystemAgent.Soul.identity(), do: "custom", else: "default"
    version = Application.spec(:optimal_system_agent, :vsn) |> to_string()
    git_hash = git_short_hash()

    IO.puts("""
    #{@bold}#{@cyan}
     ██████╗ ███████╗ █████╗
    ██╔═══██╗██╔════╝██╔══██╗
    ██║   ██║███████╗███████║
    ██║   ██║╚════██║██╔══██║
    ╚██████╔╝███████║██║  ██║
     ╚═════╝ ╚══════╝╚═╝  ╚═╝#{@reset}
    #{@bold}#{@white}Optimal System Agent#{@reset} #{@dim}#{version} (#{git_hash}) — Signal Theory Architecture#{@reset}

    #{@dim}#{provider} / #{model} | #{skill_count} skills | soul: #{soul_status}#{@reset}
    #{@dim}/help#{@reset}#{@dim} commands  •  #{@bold}/model#{@reset}#{@dim} switch providers  •  #{@bold}exit#{@reset}#{@dim} quit#{@reset}
    """)
  end

  defp git_short_hash do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {hash, 0} -> String.trim(hash)
      _ -> "dev"
    end
  rescue
    _ -> "dev"
  end

  defp get_model_name(:anthropic) do
    Application.get_env(:optimal_system_agent, :anthropic_model, "claude-sonnet-4-6")
  end

  defp get_model_name(:ollama) do
    Application.get_env(:optimal_system_agent, :ollama_model, "llama3")
  end

  defp get_model_name(:openai) do
    Application.get_env(:optimal_system_agent, :openai_model, "gpt-4o")
  end

  defp get_model_name(provider) do
    key = :"#{provider}_model"
    Application.get_env(:optimal_system_agent, key, to_string(provider))
  end

  defp print_goodbye do
    IO.puts("\n#{@dim}  goodbye#{@reset}\n")
  end

  # ── Response Formatting ─────────────────────────────────────────────

  defp print_response(response) do
    # Apply markdown rendering, then word-wrap and indent
    rendered = Markdown.render(response)
    lines = wrap_text(rendered, terminal_width() - 4)

    IO.puts("")
    Enum.each(lines, fn line ->
      IO.puts("#{@white}  #{line}#{@reset}")
    end)
    IO.puts("")
  end

  # ── Text Wrapping ───────────────────────────────────────────────────

  defp wrap_text(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if String.length(line) <= width do
        [line]
      else
        wrap_line(line, width)
      end
    end)
  end

  defp wrap_line(line, width) do
    line
    |> String.split(~r/\s+/)
    |> Enum.reduce([""], fn word, [current | rest] ->
      if String.length(current) + String.length(word) + 1 <= width do
        if current == "" do
          [word | rest]
        else
          [current <> " " <> word | rest]
        end
      else
        [word, current | rest]
      end
    end)
    |> Enum.reverse()
  end

  # ── Terminal Helpers ────────────────────────────────────────────────

  defp terminal_width do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> 80
    end
  end

  defp clear_line do
    width = terminal_width()
    IO.write("\r#{String.duplicate(" ", width)}\r")
  end

  # ── Fuzzy Command Matching ───────────────────────────────────────

  defp suggest_command(input) do
    Commands.list_commands()
    |> Enum.map(fn {name, _desc} -> {name, levenshtein(input, name)} end)
    |> Enum.filter(fn {_name, dist} -> dist <= 3 end)
    |> Enum.sort_by(fn {_name, dist} -> dist end)
    |> case do
      [{name, _} | _] -> name
      [] -> nil
    end
  end

  defp levenshtein(a, b) do
    b_len = String.length(b)
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)

    row = Enum.to_list(0..b_len)

    Enum.reduce(Enum.with_index(a_chars, 1), row, fn {a_char, i}, prev_row ->
      Enum.reduce(Enum.with_index(b_chars, 1), {[i], i - 1}, fn {b_char, j}, {curr_row, diag} ->
        cost = if a_char == b_char, do: 0, else: 1
        above = Enum.at(prev_row, j)
        left = hd(curr_row)
        val = Enum.min([above + 1, left + 1, diag + cost])
        {[val | curr_row], Enum.at(prev_row, j)}
      end)
      |> elem(0)
      |> Enum.reverse()
    end)
    |> List.last()
  end
end
