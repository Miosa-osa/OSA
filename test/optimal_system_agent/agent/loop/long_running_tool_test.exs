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
  `:timeout_ms` into `ToolOrchestrator`. Both are unbounded by default now.
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

  test "the shipped defaults impose no tool ceiling" do
    # The two knobs that killed the dispatch. Both default to no limit; either
    # regressing to a number silently caps how long any turn may work.
    assert Application.get_env(:optimal_system_agent, :tool_timeout_ms, :infinity) == :infinity

    assert Application.get_env(:optimal_system_agent, :tool_await_timeout_ms, :infinity) ==
             :infinity
  end
end
