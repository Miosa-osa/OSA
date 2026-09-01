defmodule OptimalSystemAgent.Agent.Loop.ReactLoopTurnEffortTest do
  @moduledoc """
  Per-turn effort shaping: planning turns are floored UP, tool-loop
  continuations drop to :fast so digesting a tool result stays snappy, and the
  first response of a turn keeps the user's global effort. A session that
  deliberately runs :high/:xhigh is never silently lowered.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.Effort

  defp at(effort, fun), do: Effort.with_process_override(effort, fun)

  test "the first response of a turn keeps the global effort (no override)" do
    at(:medium, fn -> assert ReactLoop.turn_effort(%{iteration: 0}) == nil end)
  end

  test "a tool-loop continuation drops to :fast at the default effort" do
    at(:medium, fn -> assert ReactLoop.turn_effort(%{iteration: 3}) == :fast end)
  end

  test "a continuation never lowers a deliberately high-effort session" do
    at(:high, fn -> assert ReactLoop.turn_effort(%{iteration: 3}) == nil end)
    at(:xhigh, fn -> assert ReactLoop.turn_effort(%{iteration: 5}) == nil end)
  end

  test "a plan-mode turn is floored up to :high" do
    at(:fast, fn ->
      assert ReactLoop.turn_effort(%{permission_mode: :plan, iteration: 2}) == :high
    end)

    at(:medium, fn ->
      assert ReactLoop.turn_effort(%{plan_mode: true, iteration: 0}) == :high
    end)
  end

  test "plan mode never lowers an already-higher session" do
    at(:xhigh, fn -> assert ReactLoop.turn_effort(%{plan_mode: true, iteration: 0}) == nil end)
  end
end
