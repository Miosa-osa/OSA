defmodule OptimalSystemAgent.Channels.CLI do
  @moduledoc """
  Interactive CLI REPL — clean, colored, responsive.
  Start with: mix osa.chat
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Commands

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @yellow IO.ANSI.yellow()
  @white IO.ANSI.white()

  def start do
    # Clear screen and print banner
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    print_banner()

    session_id = "cli_#{:rand.uniform(999_999)}"
    {:ok, _pid} = Loop.start_link(session_id: session_id, channel: :cli)

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
        IO.puts("#{@yellow}  unknown command: /#{cmd}#{@reset}")
        IO.puts("#{@dim}  type /help to see available commands#{@reset}\n")
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

  defp send_to_agent(input, session_id) do
    IO.write("#{@dim}  thinking...#{@reset}")

    case Loop.process_message(session_id, input) do
      {:ok, response} ->
        IO.write("\r#{String.duplicate(" ", 40)}\r")
        print_response(response)

      {:error, reason} ->
        IO.write("\r#{String.duplicate(" ", 40)}\r")
        IO.puts("#{@yellow}  error: #{reason}#{@reset}\n")
    end
  end

  # ── Banner ────────────────────────────────────────────────────────────

  defp print_banner do
    IO.puts("""
    #{@bold}#{@cyan}
      ___  ____    _
     / _ \\/ ___|  / \\
    | | | \\___ \\ / _ \\
    | |_| |___) / ___ \\
     \\___/|____/_/   \\_\\#{@reset}

    #{@dim}Signal Theory AI Agent#{@reset}
    #{@dim}Type #{@bold}/help#{@reset}#{@dim} for commands#{@reset}
    """)
  end

  defp print_goodbye do
    IO.puts("\n#{@dim}  goodbye#{@reset}\n")
  end

  # ── Response Formatting ────────────────────────────────────────────────

  defp print_response(response) do
    # Word-wrap and indent the response
    lines = wrap_text(response, terminal_width() - 4)

    IO.puts("")
    Enum.each(lines, fn line ->
      IO.puts("#{@white}  #{line}#{@reset}")
    end)
    IO.puts("")
  end

  # ── Text Wrapping ──────────────────────────────────────────────────────

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

  defp terminal_width do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> 80
    end
  end
end
