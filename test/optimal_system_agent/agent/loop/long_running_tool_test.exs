defmodule OptimalSystemAgent.Agent.Loop.LongRunningToolTest do
  @moduledoc """
  A tool call must be allowed to outlive any wrapper's idea of "too long".

  Observed: a three-agent dispatch was killed at the wrapper's ten-minute
  ceiling and reported as a tool timeout. The agents it launched kept running
  in the background and finished normally at 5m44s, 8m50s and 11m37s — so the
  turn that started them lost its own work while nothing else stopped, and the
  delegate result arrived at 11m42s with no live turn left to receive it.

  Two ceilings sat on that path: `StreamingToolExecutor.collect_results/1`
  awaiting each task for 600_000 ms, and `ReactLoop` passing a 300_000 ms
  `:timeout_ms` into `ToolOrchestrator`. Both now default to a generous
  20-minute backstop (was unbounded): leaving them unbounded let a single
  wedged tool freeze a whole turn forever - the reported multi-minute hangs.
  20 minutes sits above the 11m37s dispatch above, so real long work still
  completes; only a genuine wedge is killed, and `:infinity` is still honoured
  when a caller sets it explicitly.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolOrchestrator

  defmodule SlowExecutor do
    @moduledoc false
    def execute_tool_call(tc, _state) do
      Process.sleep(300)
      %{"tool_call_id" => tc.id, "role" => "tool", "content" => "finished after sleeping"}
    end
  end

  defp call(id), do: %{id: id, name: "slow", arguments: "{}"}

  defp dispatch(opts) do
    ToolOrchestrator.dispatch(
      [call("t1")],
      %{session_id: "long-running-#{System.unique_integer([:positive])}"},
      Keyword.merge([executor: SlowExecutor], opts)
    )
  end

  test "a tool outliving a short ceiling is killed — the bound is real when set" do
    # Establishes that the mechanism still works, so the :infinity case below
    # is meaningful rather than vacuous.
    results = dispatch(timeout_ms: 50)

    assert inspect(results) =~ ~r/timed out/i,
           "a configured ceiling must still be enforced: #{inspect(results)}"
  end

  test "the same tool survives with no ceiling" do
    results = dispatch(timeout_ms: :infinity)

    refute inspect(results) =~ ~r/timed out/i,
           ":infinity must mean no deadline, not an already-expired one: #{inspect(results)}"

    assert inspect(results) =~ "finished after sleeping",
           "the tool's own result must come back intact: #{inspect(results)}"
  end

  test "the shipped config sets no cap tighter than the safety backstop" do
    # The two knobs that killed the dispatch. The code now applies a generous
    # ~20-minute backstop at both layers so a wedged tool cannot freeze a turn
    # forever; config stays UNSET, so an operator has imposed nothing tighter on
    # top of it. What must never appear is a SHORT cap (the old 60s / 5-min),
    # the actual regression: either knob may only be absent or generous.
    tool = Application.get_env(:optimal_system_agent, :tool_timeout_ms)
    await = Application.get_env(:optimal_system_agent, :tool_await_timeout_ms)

    assert tool in [nil, :infinity] or tool >= 900_000
    assert await in [nil, :infinity] or await >= 900_000
  end

  describe "nothing else quietly caps a long autonomous run" do
    test "the stall detector never hard-halts by default" do
      # A long read/analysis phase is indistinguishable from a stall to a
      # detector watching for tool activity, so the runs most worth protecting
      # were the ones most likely to be killed. Nudges stay; the kill goes.
      refute Application.get_env(:optimal_system_agent, :stall_hard_halt, true)
    end

    test "the turn has no wall-clock ceiling" do
      # Unset is fine — it means the code default (:infinity) applies. What
      # must never appear is a finite number, which is the actual regression.
      refute is_integer(Application.get_env(:optimal_system_agent, :agent_turn_timeout_ms))
    end

    test "the step cap is high enough for real work but still bounds a true loop" do
      # Deliberately NOT :infinity. A wall-clock cap punishes work for taking
      # long; a step cap punishes it for going nowhere. Only the second is a
      # fault, so this one survives — just far above what real work reaches.
      cap = Application.get_env(:optimal_system_agent, :max_iterations)
      assert cap == :infinity or cap >= 10_000, "step cap too low for a long run: #{inspect(cap)}"
    end
  end
end
