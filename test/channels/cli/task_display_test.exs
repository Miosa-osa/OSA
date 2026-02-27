defmodule OptimalSystemAgent.Channels.CLI.TaskDisplayTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.TaskTracker.Task
  alias OptimalSystemAgent.Channels.CLI.TaskDisplay

  # ── Helpers ──────────────────────────────────────────────────────

  defp task(attrs) do
    struct(
      Task,
      Keyword.merge([id: "abc12345", title: "Test task", status: :pending, tokens_used: 0], attrs)
    )
  end

  defp strip_ansi(str) do
    Regex.replace(~r/\e\[[0-9;]*m/, str, "")
  end

  # ── render/2 ───────────────────────────────────────────────────

  describe "render/2" do
    test "returns empty string for empty list" do
      assert TaskDisplay.render([]) == ""
    end

    test "contains box borders" do
      result = TaskDisplay.render([task([])])
      stripped = strip_ansi(result)
      assert stripped =~ "┌"
      assert stripped =~ "┘"
      assert stripped =~ "│"
    end

    test "shows counter in header" do
      tasks = [
        task(title: "Done", status: :completed),
        task(title: "In progress", status: :in_progress),
        task(title: "Not started", status: :pending)
      ]

      result = TaskDisplay.render(tasks)
      stripped = strip_ansi(result)
      assert stripped =~ "1/3"
    end

    test "shows correct icons per status" do
      tasks = [
        task(title: "Pending task", status: :pending),
        task(title: "Active task now", status: :in_progress),
        task(title: "Completed task", status: :completed),
        task(title: "Failed task here", status: :failed)
      ]

      result = TaskDisplay.render(tasks)
      stripped = strip_ansi(result)
      assert stripped =~ "◻"
      assert stripped =~ "◼"
      assert stripped =~ "✔"
      assert stripped =~ "✘"
    end

    test "shows token count" do
      tasks = [task(title: "Token task here", tokens_used: 2100)]
      result = TaskDisplay.render(tasks)
      stripped = strip_ansi(result)
      assert stripped =~ "2.1k ↓"
    end

    test "shows raw token count under 1000" do
      tasks = [task(title: "Small token task", tokens_used: 500)]
      result = TaskDisplay.render(tasks)
      stripped = strip_ansi(result)
      assert stripped =~ "500 ↓"
    end

    test "hides token display when zero" do
      tasks = [task(title: "No tokens used", tokens_used: 0)]
      result = TaskDisplay.render(tasks)
      stripped = strip_ansi(result)
      refute stripped =~ "↓"
    end

    test "truncates long titles" do
      long = String.duplicate("x", 80)
      tasks = [task(title: long)]
      result = TaskDisplay.render(tasks, width: 44)
      stripped = strip_ansi(result)
      assert stripped =~ "…"
    end
  end

  # ── render_inline/1 ────────────────────────────────────────────

  describe "render_inline/1" do
    test "returns empty string for empty list" do
      assert TaskDisplay.render_inline([]) == ""
    end

    test "shows connector on first line" do
      tasks = [task(title: "First task", status: :completed)]
      result = TaskDisplay.render_inline(tasks)
      stripped = strip_ansi(result)
      assert stripped =~ "⎿"
      assert stripped =~ "✔"
      assert stripped =~ "First task"
    end

    test "indents subsequent lines without connector" do
      tasks = [
        task(title: "Done item here", status: :completed),
        task(title: "Active item now", status: :in_progress),
        task(title: "Pending item", status: :pending)
      ]

      result = TaskDisplay.render_inline(tasks)
      lines = String.split(result, "\n")
      assert length(lines) == 3
      first = strip_ansi(Enum.at(lines, 0))
      second = strip_ansi(Enum.at(lines, 1))
      assert first =~ "⎿"
      refute second =~ "⎿"
    end

    test "shows tokens on inline items" do
      tasks = [task(title: "Token task here", status: :in_progress, tokens_used: 1500)]
      result = TaskDisplay.render_inline(tasks)
      stripped = strip_ansi(result)
      assert stripped =~ "1.5k ↓"
    end
  end

  # ── render_compact/1 ───────────────────────────────────────────

  describe "render_compact/1" do
    test "returns empty string for empty list" do
      assert TaskDisplay.render_compact([]) == ""
    end

    test "shows counter and icons" do
      tasks = [
        task(title: "A", status: :completed),
        task(title: "B", status: :completed),
        task(title: "C", status: :in_progress),
        task(title: "D", status: :pending)
      ]

      result = TaskDisplay.render_compact(tasks)
      stripped = strip_ansi(result)
      assert stripped =~ "Tasks: 2/4"
      assert stripped =~ "✔✔◼◻"
    end
  end
end
