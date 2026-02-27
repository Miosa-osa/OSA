defmodule OptimalSystemAgent.Channels.CLI do
  @moduledoc """
  Interactive CLI REPL — clean, colored, responsive.
  Supports streaming responses, animated spinner with elapsed time/token count,
  readline-style line editing with arrow keys and history,
  markdown rendering, and signal classification indicators.
  Start with: mix osa.chat
  """
  require Logger

  alias OptimalSystemAgent.Agent.{Loop, TaskTracker}
  alias OptimalSystemAgent.Channels.CLI.{LineEditor, Markdown, PlanReview, Spinner, TaskDisplay}
  alias OptimalSystemAgent.Commands
  alias OptimalSystemAgent.Events.Bus

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @yellow IO.ANSI.yellow()
  @white IO.ANSI.white()
  @green IO.ANSI.green()

  @max_history 100

  def start do
    # Clear screen and print banner
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    print_banner()

    session_id = "cli_#{:rand.uniform(999_999)}"
    {:ok, _pid} = Loop.start_link(session_id: session_id, channel: :cli)

    # Register event handlers for CLI feedback
    register_signal_handler()
    register_orchestrator_handler()
    register_task_tracker_handler()

    # Initialize history storage in ETS
    init_history()

    loop(session_id)
  end

  defp loop(session_id) do
    prompt = "#{@bold}#{@cyan}❯#{@reset} "
    history = get_history(session_id)

    case LineEditor.readline(prompt, history) do
      :eof ->
        print_goodbye()
        System.halt(0)

      :interrupt ->
        IO.puts("")
        loop(session_id)

      {:ok, ""} ->
        loop(session_id)

      {:ok, input} ->
        input = String.trim(input)

        if input == "" do
          loop(session_id)
        else
          # Bare "exit"/"quit" handled as raw matches for speed;
          # /exit and /quit flow through Commands.execute → handle_action(:exit)
          case input do
            x when x in ["exit", "quit"] ->
              print_goodbye()
              System.halt(0)

            "clear" ->
              IO.write(IO.ANSI.clear() <> IO.ANSI.home())
              print_banner()
              IO.puts("")
              loop(session_id)

            _ ->
              add_to_history(session_id, input)
              next = process_input(input, session_id)
              loop(next)
          end
        end
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

          try do
            :ets.insert(:cli_signal_cache, {:active_task, task_id})
          rescue
            _ -> :ok
          end

        %{event: :orchestrator_agents_spawning, agent_count: count} ->
          clear_line()

          IO.puts(
            "#{@cyan}  ▶ Deploying #{count} agent#{if count > 1, do: "s", else: ""}#{@reset}"
          )

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

  defp register_task_tracker_handler do
    Bus.register_handler(:system_event, fn payload ->
      case payload do
        %{event: event, session_id: sid}
        when event in [
               :task_tracker_task_added,
               :task_tracker_task_started,
               :task_tracker_task_completed,
               :task_tracker_task_failed
             ] ->
          visible = Commands.get_setting(sid, :task_display_visible, true)

          if visible do
            try do
              tasks = TaskTracker.get_tasks(sid)

              if tasks != [] do
                output = TaskDisplay.render_inline(tasks)
                clear_line()
                IO.puts(output)
              end
            rescue
              _ -> :ok
            end
          end

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
        if output != "", do: print_response(output)
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

  defp handle_action(:exit, _session_id) do
    print_goodbye()
    System.halt(0)
  end

  defp handle_action(:clear, session_id) do
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    print_banner()
    IO.puts("")
    session_id
  end

  defp handle_action(_, session_id), do: session_id

  defp stop_session(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      _ -> :ok
    end
  end

  # ── Agent Communication ─────────────────────────────────────────────

  defp send_to_agent(input, session_id, opts \\ []) do
    spinner = Spinner.start()

    # Register per-request event handlers that forward to spinner.
    # Capture refs so we can unregister after the request completes.
    tool_ref =
      Bus.register_handler(:tool_call, fn payload ->
        if Process.alive?(spinner) do
          case payload do
            %{name: n, phase: :start, args: a} ->
              Spinner.update(spinner, {:tool_start, n, a || ""})

            %{name: n, phase: :start} ->
              Spinner.update(spinner, {:tool_start, n, ""})

            %{name: n, phase: :end, duration_ms: ms} ->
              Spinner.update(spinner, {:tool_end, n, ms})

            _ ->
              :ok
          end
        end
      end)

    llm_ref =
      Bus.register_handler(:llm_response, fn payload ->
        if Process.alive?(spinner) do
          case payload do
            %{usage: u} when is_map(u) and map_size(u) > 0 ->
              Spinner.update(spinner, {:llm_response, u})

            _ ->
              :ok
          end
        end
      end)

    result = Loop.process_message(session_id, input, opts)

    # Clean up per-request handlers to prevent accumulation
    Bus.unregister_handler(:tool_call, tool_ref)
    Bus.unregister_handler(:llm_response, llm_ref)

    case result do
      {:ok, response} ->
        {elapsed_ms, tool_count, total_tokens} = Spinner.stop(spinner)
        signal = get_cached_signal(session_id)
        show_status_line(elapsed_ms, tool_count, total_tokens, signal)
        print_response(response)
        print_separator()

      {:plan, plan_text, _signal} ->
        {elapsed_ms, _tool_count, total_tokens} = Spinner.stop(spinner)
        show_status_line(elapsed_ms, 0, total_tokens, nil)
        handle_plan_review(plan_text, input, session_id, 0)

      {:error, reason} ->
        Spinner.stop(spinner)
        IO.puts("#{@yellow}  error: #{reason}#{@reset}\n")
    end
  end

  @max_plan_revisions 5

  defp handle_plan_review(_plan_text, _original_input, _session_id, revision)
       when revision >= @max_plan_revisions do
    IO.puts("#{@dim}  ✗ Max revisions reached — plan cancelled#{@reset}\n")
  end

  defp handle_plan_review(plan_text, original_input, session_id, revision) do
    case PlanReview.review(plan_text) do
      :approved ->
        IO.puts("#{@dim}  ▶ Executing plan...#{@reset}\n")

        execute_msg =
          "Execute the following approved plan. Do not re-plan — proceed directly with implementation.\n\n#{plan_text}\n\nOriginal request: #{original_input}"

        send_to_agent(execute_msg, session_id, skip_plan: true)

      :rejected ->
        IO.puts("#{@dim}  ✗ Plan rejected#{@reset}\n")

      {:edit, feedback} ->
        IO.puts("#{@dim}  ↻ Revising plan (#{revision + 1}/#{@max_plan_revisions})...#{@reset}\n")

        revised_msg =
          "Revise your plan based on this feedback:\n\n#{feedback}\n\nOriginal plan:\n#{plan_text}\n\nOriginal request: #{original_input}"

        # Call send_to_agent_for_plan to get the revised plan directly, then loop
        revised_result = send_to_agent_for_plan(revised_msg, session_id)

        case revised_result do
          {:plan, new_plan_text} ->
            handle_plan_review(new_plan_text, original_input, session_id, revision + 1)

          :executed ->
            :ok
        end
    end
  end

  # Like send_to_agent but returns the plan result instead of recursing
  defp send_to_agent_for_plan(input, session_id) do
    spinner = Spinner.start()

    tool_ref =
      Bus.register_handler(:tool_call, fn payload ->
        if Process.alive?(spinner) do
          case payload do
            %{name: n, phase: :start, args: a} ->
              Spinner.update(spinner, {:tool_start, n, a || ""})

            %{name: n, phase: :start} ->
              Spinner.update(spinner, {:tool_start, n, ""})

            %{name: n, phase: :end, duration_ms: ms} ->
              Spinner.update(spinner, {:tool_end, n, ms})

            _ ->
              :ok
          end
        end
      end)

    llm_ref =
      Bus.register_handler(:llm_response, fn payload ->
        if Process.alive?(spinner) do
          case payload do
            %{usage: u} when is_map(u) and map_size(u) > 0 ->
              Spinner.update(spinner, {:llm_response, u})

            _ ->
              :ok
          end
        end
      end)

    result = Loop.process_message(session_id, input)

    Bus.unregister_handler(:tool_call, tool_ref)
    Bus.unregister_handler(:llm_response, llm_ref)

    case result do
      {:plan, plan_text, _signal} ->
        {elapsed_ms, _tool_count, total_tokens} = Spinner.stop(spinner)
        show_status_line(elapsed_ms, 0, total_tokens, nil)
        {:plan, plan_text}

      {:ok, response} ->
        {elapsed_ms, tool_count, total_tokens} = Spinner.stop(spinner)
        signal = get_cached_signal(session_id)
        show_status_line(elapsed_ms, tool_count, total_tokens, signal)
        print_response(response)
        print_separator()
        :executed

      {:error, reason} ->
        Spinner.stop(spinner)
        IO.puts("#{@yellow}  error: #{reason}#{@reset}\n")
        :executed
    end
  end

  defp show_status_line(elapsed_ms, tool_count, total_tokens, signal) do
    parts = ["#{@green}✓#{@dim} " <> format_elapsed(elapsed_ms)]
    parts = if tool_count > 0, do: parts ++ ["#{tool_count} tools"], else: parts
    parts = if total_tokens > 0, do: parts ++ [format_tokens(total_tokens)], else: parts

    parts =
      case signal do
        %{mode: mode, genre: genre, weight: weight} ->
          parts ++ ["#{mode} · #{genre} · w#{Float.round(weight, 1)}"]

        _ ->
          parts
      end

    IO.puts("#{@dim}  #{Enum.join(parts, " · ")}#{@reset}")
  end

  defp print_separator do
    width = terminal_width()
    IO.puts("\n#{@dim}#{String.duplicate("─", width)}#{@reset}")
  end

  defp format_elapsed(ms) when ms < 1_000, do: "<1s"
  defp format_elapsed(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"

  defp format_elapsed(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1_000)
    "#{mins}m#{secs}s"
  end

  defp format_tokens(0), do: ""
  defp format_tokens(n) when n < 1_000, do: "↓ #{n}"
  defp format_tokens(n), do: "↓ #{Float.round(n / 1_000, 1)}k"

  # ── History ──────────────────────────────────────────────────────────

  defp init_history do
    try do
      :ets.new(:cli_history, [:set, :public, :named_table])
    rescue
      ArgumentError -> :cli_history
    end
  end

  defp get_history(session_id) do
    case :ets.lookup(:cli_history, session_id) do
      [{^session_id, entries}] -> entries
      _ -> []
    end
  rescue
    _ -> []
  end

  defp add_to_history(session_id, input) do
    current = get_history(session_id)

    # Skip consecutive duplicates
    updated =
      case current do
        [^input | _] -> current
        _ -> [input | Enum.take(current, @max_history - 1)]
      end

    try do
      :ets.insert(:cli_history, {session_id, updated})
    rescue
      _ -> :ok
    end
  end

  # ── Banner ──────────────────────────────────────────────────────────

  defp print_banner do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
    model = get_model_name(provider)
    skill_count = length(OptimalSystemAgent.Skills.Registry.list_tools_direct())
    soul_status = if OptimalSystemAgent.Soul.identity(), do: "custom", else: "default"
    version = Application.spec(:optimal_system_agent, :vsn) |> to_string()
    git_hash = git_short_hash()
    cwd = prompt_dir()
    width = terminal_width()

    IO.puts("""
    #{@bold}#{@cyan}
     ██████╗ ███████╗ █████╗
    ██╔═══██╗██╔════╝██╔══██╗
    ██║   ██║███████╗███████║
    ██║   ██║╚════██║██╔══██║
    ╚██████╔╝███████║██║  ██║
     ╚═════╝ ╚══════╝╚═╝  ╚═╝#{@reset}
    #{@bold}#{@white}Optimal System Agent#{@reset} #{@dim}v#{version} (#{git_hash})#{@reset}
    #{@dim}#{provider} / #{model} · #{skill_count} skills · soul: #{soul_status}#{@reset}
    #{@dim}#{cwd}#{@reset}
    #{@dim}/help#{@reset} #{@dim}commands  ·  #{@bold}/model#{@reset} #{@dim}switch  ·  #{@bold}exit#{@reset} #{@dim}quit#{@reset}
    #{@dim}#{String.duplicate("─", width)}#{@reset}
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

  # ── Directory Display ──────────────────────────────────────────────

  defp prompt_dir do
    cwd = File.cwd!()
    home = System.get_env("HOME") || ""

    shortened =
      if home != "" and String.starts_with?(cwd, home) do
        "~" <> String.trim_leading(cwd, home)
      else
        cwd
      end

    # Show abbreviated path: ~/…/ProjectName for deep paths
    parts = Path.split(shortened)

    case length(parts) do
      n when n > 3 -> "~/…/" <> List.last(parts)
      _ -> shortened
    end
  rescue
    _ -> "."
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
