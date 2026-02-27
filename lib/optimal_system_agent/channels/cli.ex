defmodule OptimalSystemAgent.Channels.CLI do
  @moduledoc """
  Interactive CLI REPL — clean, colored, responsive.
  Start with: mix osa.chat
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @green IO.ANSI.green()
  @yellow IO.ANSI.yellow()
  @magenta IO.ANSI.magenta()
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

      "status\n" ->
        print_status()
        loop(session_id)

      "clear\n" ->
        IO.write(IO.ANSI.clear() <> IO.ANSI.home())
        print_banner()
        IO.puts("")
        loop(session_id)

      "help\n" ->
        print_help()
        loop(session_id)

      input ->
        input = String.trim(input)

        unless input == "" do
          # Show thinking indicator
          IO.write("#{@dim}  thinking...#{@reset}")

          case Loop.process_message(session_id, input) do
            {:ok, response} ->
              # Clear the thinking indicator
              IO.write("\r#{String.duplicate(" ", 40)}\r")
              print_response(response)

            {:error, reason} ->
              IO.write("\r#{String.duplicate(" ", 40)}\r")
              IO.puts("#{@yellow}  error: #{reason}#{@reset}\n")
          end
        end

        loop(session_id)
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
    #{@dim}Type #{@bold}help#{@reset}#{@dim} for commands#{@reset}
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

  # ── Commands ───────────────────────────────────────────────────────────

  defp print_status do
    providers = OptimalSystemAgent.Providers.Registry.list_providers()
    skills = OptimalSystemAgent.Skills.Registry.list_tools()
    memory_stats = OptimalSystemAgent.Agent.Memory.memory_stats()

    IO.puts("""

    #{@bold}#{@cyan}  Status#{@reset}
    #{@dim}  ──────────────────────────────#{@reset}
    #{@green}  providers  #{@reset}#{length(providers)} loaded
    #{@green}  skills     #{@reset}#{length(skills)} available
    #{@green}  sessions   #{@reset}#{memory_stats[:session_count] || 0} stored
    #{@green}  memory     #{@reset}#{memory_stats[:long_term_size] || 0} bytes
    #{@green}  http       #{@reset}port #{Application.get_env(:optimal_system_agent, :http_port, 8089)}
    #{@dim}  ──────────────────────────────#{@reset}
    """)
  end

  defp print_help do
    IO.puts("""

    #{@bold}#{@cyan}  Commands#{@reset}
    #{@dim}  ──────────────────────────────#{@reset}
    #{@magenta}  exit#{@reset}     quit the session
    #{@magenta}  clear#{@reset}    clear the screen
    #{@magenta}  status#{@reset}   show system info
    #{@magenta}  help#{@reset}     show this message
    #{@dim}  ──────────────────────────────#{@reset}

    #{@dim}  Just type naturally. OSA classifies
    #{@dim}  your intent and responds accordingly.#{@reset}
    """)
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
