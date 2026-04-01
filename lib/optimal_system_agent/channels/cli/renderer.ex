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
    version = Application.spec(:optimal_system_agent, :vsn) |> to_string()
    cwd = prompt_dir()
    width = min(terminal_width(), 80)

    # Border title
    title = " #{@bold}#{@cyan}OSA#{@reset} #{@dim}v#{version}#{@reset} "
    title_visible = "OSA v#{version}"

    # Build the bordered box
    inner_width = width - 4
    top_border = "#{@dim}╭─#{@reset}#{title}#{@dim}#{String.duplicate("─", max(inner_width - String.length(title_visible) - 3, 0))}╮#{@reset}"

    # Left content
    welcome = "#{@bold}#{@white}Welcome to OSA#{@reset}"
    model_line = "#{@dim}#{provider} / #{model}#{@reset}"
    tools_line = "#{@dim}#{tool_count} tools · #{cwd}#{@reset}"

    # Tips
    tips = [
      "#{@yellow}Tips#{@reset}",
      "#{@dim}/help — list commands#{@reset}",
      "#{@dim}/model — switch model#{@reset}",
      "#{@dim}/login — connect provider#{@reset}",
      "#{@dim}/setup — reconfigure#{@reset}"
    ]

    # Render bordered box
    IO.puts("")
    IO.puts("  #{top_border}")

    # Content lines
    left_lines = [welcome, "", model_line, tools_line]
    max_lines = max(length(left_lines), length(tips))

    left_width = div(inner_width, 2)
    right_width = inner_width - left_width - 1

    for i <- 0..(max_lines - 1) do
      left = Enum.at(left_lines, i, "")
      right = Enum.at(tips, i, "")

      left_padded = pad_visible(left, left_width)
      right_padded = pad_visible(right, right_width)

      separator = if i < length(tips), do: "#{@dim}│#{@reset}", else: " "
      IO.puts("  #{@dim}│#{@reset} #{left_padded}#{separator}#{right_padded} #{@dim}│#{@reset}")
    end

    bottom_border = "#{@dim}╰#{String.duplicate("─", inner_width + 2)}╯#{@reset}"
    IO.puts("  #{bottom_border}")
    IO.puts("")
  end

  defp pad_visible(str, width) do
    vis_len = visible_length(str)
    padding = max(width - vis_len, 0)
    str <> String.duplicate(" ", padding)
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
      width = terminal_width()
      # Leave room for the gutter: "  ⎿  " = 5 chars
      lines = wrap_text(rendered, width - 6)

      IO.puts("")

      Enum.with_index(lines, fn line, idx ->
        gutter = if idx == 0, do: "#{@dim}  ⎿  #{@reset}", else: "#{@dim}  │  #{@reset}"
        IO.puts("#{gutter}#{@white}#{line}#{@reset}")
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

  # ── Time / Token Formatters (delegates to shared Format module) ──────

  defdelegate format_elapsed(ms), to: OptimalSystemAgent.Channels.CLI.Format
  defdelegate format_tokens(n), to: OptimalSystemAgent.Channels.CLI.Format, as: :format_tokens_arrow

  def format_duration_ms(nil), do: ""
  def format_duration_ms(ms) when is_number(ms), do: format_elapsed(ms)
  def format_duration_ms(_), do: ""

  # ── Terminal Helpers ────────────────────────────────────────────────

  defdelegate terminal_width(), to: OptimalSystemAgent.Channels.CLI.Format

  def clear_line do
    width = terminal_width()
    IO.write("\r#{String.duplicate(" ", width)}\r")
  end

  # ── Text Wrapping ───────────────────────────────────────────────────

  def wrap_text(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if visible_length(line) <= width do
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
      if visible_length(current) + visible_length(word) + 1 <= width do
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

  # Strip ANSI escape codes before measuring visible character width.
  # ANSI codes (\e[...m) have zero display width but add to String.length.
  defp visible_length(str) do
    str
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.length()
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

  defp get_model_name(provider) do
    OptimalSystemAgent.Channels.CLI.Format.get_model_name(provider)
  end
end
