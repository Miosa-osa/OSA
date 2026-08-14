defmodule OptimalSystemAgent.Channels.CLI.DiffRenderer do
  @moduledoc """
  Renders unified diffs with ANSI colors for the CLI.

  Colorizes diff output: green for additions, red for deletions,
  cyan for hunk headers, dim for context and meta lines.
  """

  @reset IO.ANSI.reset()
  @green IO.ANSI.green()
  @red IO.ANSI.red()
  @cyan IO.ANSI.cyan()
  @dim IO.ANSI.faint()

  @doc "Render a unified diff string with ANSI colors."
  @spec render(String.t()) :: String.t()
  def render(diff_text) when is_binary(diff_text) do
    diff_text
    |> String.split("\n")
    |> Enum.map(&colorize_line/1)
    |> Enum.join("\n")
  end

  def render(_), do: ""

  @doc "Render addition/deletion stats as colored string."
  @spec render_stats(map()) :: String.t()
  def render_stats(%{additions: a, deletions: d}) do
    "#{@green}+#{a}#{@reset} #{@red}-#{d}#{@reset}"
  end

  def render_stats(%{"additions" => a, "deletions" => d}) do
    render_stats(%{additions: a, deletions: d})
  end

  def render_stats(_), do: ""

  @doc "Print a diff with indentation suitable for the spinner tool tree."
  @spec print_indented(String.t(), map() | nil) :: :ok
  def print_indented(diff_text, stats \\ nil) do
    # A diff body is file *content*, so every line of it is untrusted. Scrub
    # BEFORE `render/1`, never after: `render/1` adds OSA's own colour codes,
    # and scrubbing the rendered string would strip those too, leaving the
    # operator staring at literal `[32m` residue. Scrubbing first means the only
    # escapes reaching the terminal are the ones this module put there.
    #
    # Dropping `\r` matters as much as dropping ESC here — a carriage return in
    # content re-draws over the line already printed, which is how a removed
    # line is made to look like a kept one.
    diff_text
    |> OptimalSystemAgent.CLI.Sanitize.scrub_block()
    |> render()
    |> String.split("\n")
    |> Enum.each(fn line ->
      IO.puts("    #{line}")
    end)

    if stats do
      IO.puts("    #{render_stats(stats)}")
    end

    :ok
  end

  # --- Private ---

  # Meta lines (+++/---) must match before single-char prefixes (+/-)
  defp colorize_line("+++" <> _ = line), do: "#{@dim}#{line}#{@reset}"
  defp colorize_line("---" <> _ = line), do: "#{@dim}#{line}#{@reset}"
  defp colorize_line("@@" <> _ = line), do: "#{@cyan}#{line}#{@reset}"
  defp colorize_line("+" <> _ = line), do: "#{@green}#{line}#{@reset}"
  defp colorize_line("-" <> _ = line), do: "#{@red}#{line}#{@reset}"
  defp colorize_line(line), do: "#{@dim}#{line}#{@reset}"
end
