defmodule OptimalSystemAgent.Channels.CLI.Markdown do
  @moduledoc """
  Lightweight markdown-to-ANSI renderer for CLI output.
  Handles headers, bold, italic, inline code, code blocks, and lists.
  """

  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @yellow IO.ANSI.yellow()
  @underline IO.ANSI.underline()
  @reset IO.ANSI.reset()

  @doc "Render markdown text with ANSI escape codes."
  @spec render(String.t()) :: String.t()
  def render(text) do
    text
    |> String.split("\n")
    |> render_lines(false, [])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # Process lines, tracking whether we're inside a code block
  defp render_lines([], _in_code, acc), do: acc

  defp render_lines(["```" <> _ | rest], false, acc) do
    render_lines(rest, true, acc)
  end

  defp render_lines(["```" <> _ | rest], true, acc) do
    render_lines(rest, false, acc)
  end

  defp render_lines([line | rest], true, acc) do
    render_lines(rest, true, ["#{@dim}#{line}#{@reset}" | acc])
  end

  defp render_lines([line | rest], false, acc) do
    rendered = render_line(line)
    render_lines(rest, false, [rendered | acc])
  end

  defp render_line("## " <> heading), do: "#{@bold}#{heading}#{@reset}"
  defp render_line("# " <> heading), do: "#{@bold}#{heading}#{@reset}"

  defp render_line("- " <> item) do
    " \u2022 #{render_inline(item)}"
  end

  defp render_line("* " <> item) do
    " \u2022 #{render_inline(item)}"
  end

  defp render_line(line), do: render_inline(line)

  defp render_inline(text) do
    text
    |> replace_inline_code()
    |> replace_bold()
    |> replace_italic()
  end

  defp replace_inline_code(text) do
    Regex.replace(~r/`([^`]+)`/, text, "#{@yellow}\\1#{@reset}")
  end

  defp replace_bold(text) do
    Regex.replace(~r/\*\*(.+?)\*\*/, text, "#{@bold}\\1#{@reset}")
  end

  defp replace_italic(text) do
    Regex.replace(~r/(?<!\*)\*([^*]+)\*(?!\*)/, text, "#{@underline}\\1#{@reset}")
  end
end
