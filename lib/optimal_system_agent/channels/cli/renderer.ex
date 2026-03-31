defmodule OptimalSystemAgent.Channels.CLI.Renderer do
  @moduledoc """
  Output formatting, colors, display, and terminal helpers for the CLI REPL.

  Handles the banner, response printing, status line, text wrapping,
  separators, and terminal geometry queries.
  """

  alias OptimalSystemAgent.Channels.CLI.Markdown

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @yellow IO.ANSI.yellow()
  @white IO.ANSI.white()
  @green IO.ANSI.green()

  # ── Banner ──────────────────────────────────────────────────────────

  def print_banner do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
    model = get_model_name(provider)
    tool_count = length(OptimalSystemAgent.Tools.Registry.list_tools_direct())
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
    #{@dim}#{provider} / #{model} · #{tool_count} tools · soul: #{soul_status}#{@reset}
    #{@dim}#{cwd}#{@reset}
    #{@dim}/help#{@reset} #{@dim}commands  ·  #{@bold}/model#{@reset} #{@dim}switch  ·  #{@bold}exit#{@reset} #{@dim}quit#{@reset}
    #{proactive_banner_line()}#{@dim}#{String.duplicate("─", width)}#{@reset}
    """)
  end

  def print_goodbye do
    IO.puts("\n#{@dim}  goodbye#{@reset}\n")
  end

  def print_separator do
    width = terminal_width()
    IO.puts("\n#{@dim}#{String.duplicate("─", width)}#{@reset}")
  end

  # ── Response Formatting ─────────────────────────────────────────────

  def print_response(response, opts \\ []) do
    unless opts[:already_streamed] do
      rendered = Markdown.render(response)
      lines = wrap_text(rendered, terminal_width() - 4)

      IO.puts("")

      Enum.each(lines, fn line ->
        IO.puts("#{@white}  #{line}#{@reset}")
      end)

      IO.puts("")
    end
  end

  # ── Status Line ─────────────────────────────────────────────────────

  def show_status_line(elapsed_ms, tool_count, total_tokens, cost_usd \\ nil) do
    parts = ["#{@green}✓#{@dim} " <> format_elapsed(elapsed_ms)]
    parts = if tool_count > 0, do: parts ++ ["#{tool_count} tools"], else: parts
    parts = if total_tokens > 0, do: parts ++ [format_tokens(total_tokens)], else: parts

    parts =
      if is_number(cost_usd) and cost_usd > 0 do
        parts ++ ["$#{:erlang.float_to_binary(cost_usd * 1.0, decimals: 4)}"]
      else
        parts
      end

    parts =
      try do
        case :ets.lookup(:cli_signal_cache, :context_pressure) do
          [{:context_pressure, util}] when util >= 50.0 ->
            label =
              cond do
                util >= 95.0 -> "#{IO.ANSI.red()}ctx #{Float.round(util, 0)}%#{@dim}"
                util >= 85.0 -> "#{IO.ANSI.red()}ctx #{Float.round(util, 0)}%#{@dim}"
                util >= 70.0 -> "#{@yellow}ctx #{Float.round(util, 0)}%#{@dim}"
                true -> "ctx #{Float.round(util, 0)}%"
              end

            parts ++ [label]

          _ ->
            parts
        end
      rescue
        _ -> parts
      end

    IO.puts("#{@dim}  #{Enum.join(parts, " · ")}#{@reset}")
  end

  # ── Event Display ───────────────────────────────────────────────────

  def context_pressure_bar(util) when util >= 95.0, do: "█████ CRITICAL"
  def context_pressure_bar(util) when util >= 90.0, do: "████░ HIGH"
  def context_pressure_bar(util) when util >= 85.0, do: "███░░ ELEVATED"
  def context_pressure_bar(util) when util >= 70.0, do: "██░░░ WARM"
  def context_pressure_bar(_util), do: "█░░░░"

  # ── Time / Token Formatters ─────────────────────────────────────────

  def format_elapsed(ms) when ms < 1_000, do: "<1s"
  def format_elapsed(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"

  def format_elapsed(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1_000)
    if secs > 0, do: "#{mins}m #{secs}s", else: "#{mins}m"
  end

  def format_duration_ms(nil), do: ""
  def format_duration_ms(ms) when is_number(ms), do: format_elapsed(ms)
  def format_duration_ms(_), do: ""

  def format_tokens(0), do: ""
  def format_tokens(n) when n < 1_000, do: "↓ #{n}"
  def format_tokens(n), do: "↓ #{Float.round(n / 1_000, 1)}k"

  # ── Terminal Helpers ────────────────────────────────────────────────

  def terminal_width do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> 80
    end
  end

  def clear_line do
    width = terminal_width()
    IO.write("\r#{String.duplicate(" ", width)}\r")
  end

  # ── Text Wrapping ───────────────────────────────────────────────────

  def wrap_text(text, width) do
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

  def prompt_dir do
    cwd = File.cwd!()
    home = System.get_env("HOME") || ""

    shortened =
      if home != "" and String.starts_with?(cwd, home) do
        "~" <> String.trim_leading(cwd, home)
      else
        cwd
      end

    parts = Path.split(shortened)

    case length(parts) do
      n when n > 3 -> "~/…/" <> List.last(parts)
      _ -> shortened
    end
  rescue
    _ -> "."
  end

  # ── Private Helpers ─────────────────────────────────────────────────

  defp proactive_banner_line do
    ""
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
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
    Application.get_env(:optimal_system_agent, :ollama_model, "detecting...")
  end

  defp get_model_name(:openai) do
    Application.get_env(:optimal_system_agent, :openai_model, "gpt-4o")
  end

  defp get_model_name(provider) do
    key = :"#{provider}_model"
    Application.get_env(:optimal_system_agent, key, to_string(provider))
  end
end
