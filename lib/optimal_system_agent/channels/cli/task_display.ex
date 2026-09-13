defmodule OptimalSystemAgent.Channels.CLI.TaskDisplay do
  @moduledoc """
  Pure function renderer for the task tracker checklist.

  Returns ANSI strings — no IO, no GenServer, no side effects.
  """

  alias OptimalSystemAgent.Agent.Tasks.Tracker.Task
  alias OptimalSystemAgent.CLI.Sanitize
  alias OptimalSystemAgent.CLI.Width, as: W

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @green IO.ANSI.green()
  @red IO.ANSI.red()

  @icons %{
    pending: "◻",
    in_progress: "◼",
    completed: "✔",
    failed: "✘"
  }

  @icon_colors %{
    pending: @dim,
    in_progress: @cyan <> @bold,
    completed: @green,
    failed: @red
  }

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Render a full task box with border, counter header, icons, and token counts.

  Options:
  - `:width` — box width (default: 44)
  """
  @spec render([%Task{}], keyword()) :: String.t()
  def render(tasks, opts \\ [])
  def render([], _opts), do: ""

  def render(tasks, opts) do
    width = Keyword.get(opts, :width, 44)
    completed = Enum.count(tasks, &(&1.status == :completed))
    total = length(tasks)
    inner = width - 4

    # The top border must own exactly the same columns as the rows below it.
    # It was sized off `inner` (width - 4) with a hand-counted literal allowance,
    # which came out 3 columns short of `width` for EVERY task box, ascii
    # included — the header rail visibly stopped before the right-hand corner.
    # Derive the fill from the pieces actually being concatenated instead.
    label = " Tasks "
    tally = " #{completed}/#{total} "
    # "┌" + "─" + label + fill + tally + "─" + "┐" == width
    fill = max(width - 4 - W.visible(label) - W.visible(tally), 0)
    header = "─" <> label <> String.duplicate("─", fill) <> tally <> "─"

    top = "#{@dim}┌#{header}┐#{@reset}"
    bottom = "#{@dim}└#{String.duplicate("─", width - 2)}┘#{@reset}"

    rows =
      Enum.map(tasks, fn task ->
        icon_color = Map.get(@icon_colors, task.status, @dim)
        icon = Map.get(@icons, task.status, "?")
        tokens = format_tokens(task.tokens_used)

        # Available space for title: inner width - icon(2) - spacing
        title_space = inner - 2

        title_space =
          if tokens != "", do: title_space - W.visible(tokens) - 1, else: title_space

        # COLUMNS, not graphemes. Task titles are MODEL-AUTHORED and routinely
        # contain emoji, each of which is one grapheme but two columns — sized by
        # `String.length/1` every one of them tore the `│` border.
        # Scrub BEFORE fitting. `W.fit/2` measures with `strip_ansi/1` but
        # returns the ORIGINAL string, so an escape that fits within the column
        # budget passes straight through it — width arithmetic is not a
        # sanitizer. Scrubbing first also makes the measurement honest: the
        # columns counted are the columns that will actually be printed.
        title = W.fit(Sanitize.scrub_line(task.title), title_space)

        # Build the row content
        content = "#{icon_color}#{icon}#{@reset} #{title_color(task.status)}#{title}#{@reset}"
        # Pad to fill the box. Measure the PRE-COLOUR title: `content` above has
        # ANSI interpolated into it, so measuring that instead would have to
        # strip it back out again.
        visible_len = 2 + W.visible(title)

        pad =
          if tokens != "" do
            remaining = inner - visible_len - W.visible(tokens)
            String.duplicate(" ", max(remaining, 1)) <> "#{@dim}#{tokens}#{@reset}"
          else
            remaining = inner - visible_len
            String.duplicate(" ", max(remaining, 0))
          end

        "#{@dim}│#{@reset} #{content}#{pad} #{@dim}│#{@reset}"
      end)

    Enum.join([top | rows] ++ [bottom], "\n")
  end

  @doc """
  Render inline the upstream agent CLI-style task list with `⎿` connector.

  Example output:
      ⎿  ✔ Explore codebase structure
         ✔ Identify authentication patterns
         ◼ Implement user endpoints
         ◻ Write integration tests
  """
  @spec render_inline([%Task{}]) :: String.t()
  def render_inline([]), do: ""

  def render_inline(tasks) do
    indexed = Enum.with_index(tasks, 1)
    [{first, idx} | rest] = indexed

    first_line =
      "  #{@dim}⎿#{@reset}  #{icon_str(first)} #{@dim}##{idx}#{@reset} #{title_str(first)}#{tokens_str(first)}"

    rest_lines =
      Enum.map(rest, fn {task, i} ->
        "     #{icon_str(task)} #{@dim}##{i}#{@reset} #{title_str(task)}#{tokens_str(task)}"
      end)

    Enum.join([first_line | rest_lines], "\n")
  end

  @doc """
  Render a compact single-line summary.

  Example: `Tasks: 3/7 ✔✔✔◼◻◻◻`
  """
  @spec render_compact([%Task{}]) :: String.t()
  def render_compact([]), do: ""

  def render_compact(tasks) do
    completed = Enum.count(tasks, &(&1.status == :completed))
    total = length(tasks)

    icons =
      Enum.map_join(tasks, "", fn task ->
        color = Map.get(@icon_colors, task.status, @dim)
        icon = Map.get(@icons, task.status, "?")
        "#{color}#{icon}#{@reset}"
      end)

    "#{@dim}Tasks: #{completed}/#{total}#{@reset} #{icons}"
  end

  # ── Private ────────────────────────────────────────────────────────

  defp title_color(:completed), do: @dim
  defp title_color(:failed), do: @red
  defp title_color(:in_progress), do: @cyan
  defp title_color(_), do: ""

  defp format_tokens(0), do: ""
  defp format_tokens(n) when n < 1_000, do: "#{n} ↓"
  defp format_tokens(n), do: "#{Float.round(n / 1_000, 1)}k ↓"

  defp icon_str(task) do
    color = Map.get(@icon_colors, task.status, @dim)
    icon = Map.get(@icons, task.status, "?")
    "#{color}#{icon}#{@reset}"
  end

  # Task titles are MODEL-AUTHORED. `render_inline/1` has no width budget to
  # clip them, so this was the one path that put a title on the terminal
  # completely untouched. Scrub before the colour is wrapped around it.
  defp title_str(task) do
    "#{title_color(task.status)}#{Sanitize.scrub_line(task.title)}#{@reset}"
  end

  defp tokens_str(%{tokens_used: n}) when n > 0 do
    " #{@dim}#{format_tokens(n)}#{@reset}"
  end

  defp tokens_str(_), do: ""
end
