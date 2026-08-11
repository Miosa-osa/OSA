defmodule OptimalSystemAgent.Channels.CLI.PlanReview do
  @moduledoc """
  Plan review UI — renders a plan in a bordered box with an approval selector.

  Used by the CLI channel when the agent loop returns `{:plan, text}`
  instead of executing immediately. The user can approve, reject, or provide
  feedback to refine the plan.
  """

  alias OptimalSystemAgent.Channels.CLI.Markdown
  alias OptimalSystemAgent.Onboarding.Selector

  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @white IO.ANSI.white()
  @reset IO.ANSI.reset()

  @doc """
  Render a plan and prompt for user approval.

  Returns:
    - `:approved` — user approved the plan
    - `:rejected` — user rejected the plan
    - `{:edit, feedback}` — user provided feedback for revision
  """
  @spec review(String.t()) :: :approved | :rejected | {:edit, String.t()}
  def review(plan_text) do
    render_plan_box(plan_text)
    IO.puts("")
    prompt_approval()
  end

  # ── Plan Box Rendering ───────────────────────────────────────────

  defp render_plan_box(plan_text) do
    width = box_width()
    # 2 for border + 2 for padding
    inner = width - 4

    # Render markdown then word-wrap
    rendered = Markdown.render(plan_text)
    lines = wrap_text(rendered, inner)

    # Top border
    IO.puts("")

    IO.puts(
      "  #{@dim}┌─ #{@reset}#{@bold}#{@cyan}Plan#{@reset} #{@dim}#{String.duplicate("─", max(width - 10, 1))}┐#{@reset}"
    )

    # Empty line after top border
    IO.puts("  #{@dim}│#{@reset}#{String.duplicate(" ", width - 2)}#{@dim}│#{@reset}")

    # Plan content
    Enum.each(lines, fn line ->
      # Strip ANSI for length calculation, pad with spaces
      visible_len = visible_length(line)
      padding = max(inner - visible_len, 0)

      IO.puts(
        "  #{@dim}│#{@reset} #{@white}#{line}#{@reset}#{String.duplicate(" ", padding)} #{@dim}│#{@reset}"
      )
    end)

    # Empty line before bottom border
    IO.puts("  #{@dim}│#{@reset}#{String.duplicate(" ", width - 2)}#{@dim}│#{@reset}")

    # Bottom border
    IO.puts("  #{@dim}└#{String.duplicate("─", width - 2)}┘#{@reset}")
  end

  defp prompt_approval do
    lines = [
      {:option, "Approve — proceed with this plan", :approve},
      {:option, "Reject — cancel and return to prompt", :reject},
      {:input, "Edit — provide feedback to refine the plan", "feedback>"}
    ]

    case Selector.select(lines) do
      {:selected, :approve} -> :approved
      {:selected, :reject} -> :rejected
      {:input, text} -> {:edit, text}
      nil -> :rejected
    end
  end

  # ── Text Utilities ───────────────────────────────────────────────

  defp box_width do
    case :io.columns() do
      {:ok, cols} -> max(min(cols - 4, 80), 20)
      _ -> 76
    end
  end

  # Width arithmetic is SHARED, not copied. This module used to carry a
  # byte-for-byte duplicate of the renderer's already-known-bad helpers:
  # `String.length/1` as a display width, and an ANSI strip that removed only
  # SGR. That is worse here than in the renderer, because the content in this box
  # is MODEL-AUTHORED and the box is the CONSENT GATE the user reads before
  # approving a plan — a sheared box is a misread plan.
  defp wrap_text(text, width), do: OptimalSystemAgent.CLI.Width.wrap(text, width)

  defp visible_length(str), do: OptimalSystemAgent.CLI.Width.visible(str)
end
