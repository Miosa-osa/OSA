defmodule OptimalSystemAgent.Agent.EffortDocsAccuracyTest do
  @moduledoc """
  The prompt must not describe an effort ladder the code does not have.

  `SYSTEM.md` documented four levels — `low`/`medium`/`high`/`max` — with
  thinking budgets and "10 / 30 / 50 / 100 iterations max". `Effort` has five,
  named `fast`/`medium`/`high`/`xhigh`/`ultra`, with backstops of
  50/100/150/2000/4000. Every figure and three of the four names were wrong, and
  the model reads that text as fact about its own configuration: a model told it
  has ten iterations on `low` will pace a task it has fifty rounds to finish.

  These assertions read the live `Effort` table rather than restating it, so the
  next change to the ladder fails here instead of quietly re-introducing the
  drift.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Effort

  @system_md Path.join([__DIR__, "..", "..", "priv", "prompts", "SYSTEM.md"])

  defp doc, do: File.read!(@system_md)

  test "the retired figure and the level that never existed are gone" do
    text = doc()
    refute text =~ "10 iterations max"
    refute text =~ "1K thinking budget"
  end

  test "every level the code has is named in the prompt" do
    text = doc()
    effort_section = text |> String.split("### Effort Levels") |> List.last()

    for level <- [:fast, :medium, :high, :xhigh, :ultra] do
      assert effort_section =~ "**#{level}**",
             "SYSTEM.md does not document the `#{level}` effort level"
    end
  end

  test "the iteration figures the prompt quotes are the ones the code uses" do
    text = doc()

    for level <- [:fast, :medium, :high, :xhigh, :ultra] do
      max_iterations = Effort.get(level).max_iterations

      assert text =~ "backstop #{max_iterations}" or
               text =~ "backstop) #{max_iterations}" or
               text =~ "#{max_iterations})",
             "SYSTEM.md does not quote #{level}'s real max_iterations (#{max_iterations})"
    end
  end

  test "the prompt says the iteration ceiling is a backstop, not a budget" do
    # The figures are only safe to publish to the model alongside this: a
    # ceiling read as an allowance makes a model stop short of a finished task.
    assert doc() =~ "backstops, not budgets"
  end
end
