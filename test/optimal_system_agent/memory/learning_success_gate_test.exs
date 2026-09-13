defmodule OptimalSystemAgent.Memory.LearningSuccessGateTest do
  @moduledoc """
  Behavioral regression tests for the success-telemetry gate in
  `OptimalSystemAgent.Memory.Learning` (SICA honesty cleanup, 2026-08-27).

  The old code upserted a "Tool X succeeded" pattern row on EVERY successful
  tool call — 2,779 rows of pure telemetry masquerading as learning, all with
  success_rate 1.0. The gate deletes that upsert path. These tests pin BOTH
  directions of the gate:

    * a success observation must NOT create or update any pattern row
      (telemetry is recorded via ETS working memory + interaction count
      instead), and
    * a failure observation must STILL create its VIGIL-classified error
      pattern (the gate must not kill real learning).

  async: false — Memory.Learning is a shared singleton GenServer backed by
  the shared SQLite DB; pattern assertions must not race other tests.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Memory.Learning

  @junk_prefix "Tool gate-test-tool succeeded"

  defp junk_pattern_rows do
    {:ok, patterns} = Learning.patterns()
    Enum.filter(patterns, &String.starts_with?(&1.description, @junk_prefix))
  end

  defp error_pattern_rows do
    {:ok, patterns} = Learning.patterns()
    Enum.filter(patterns, &(&1.trigger == "error:gate-test-tool:permission_denied"))
  end

  test "a success observation creates NO pattern row (the junk factory is dead)" do
    assert junk_pattern_rows() == [], "precondition: no leftover junk row from a prior run"

    Learning.observe(%{
      type: :success,
      tool_name: "gate-test-tool",
      duration_ms: 42
    })

    # observe/1 is a cast; let the GenServer drain it.
    :timer.sleep(50)

    assert junk_pattern_rows() == [],
           "a success observation must never create a 'Tool X succeeded' pattern"
  end

  test "repeated success observations never upsert a junk row" do
    for _ <- 1..3 do
      Learning.observe(%{type: :success, tool_name: "gate-test-tool", duration_ms: 10})
    end

    :timer.sleep(50)

    assert junk_pattern_rows() == [],
           "repeating a success must not accumulate occurrence counts into a pattern"
  end

  test "a failure observation STILL captures its VIGIL error pattern (gate did not kill learning)" do
    assert error_pattern_rows() == [], "precondition: no leftover row from a prior run"

    Learning.error("gate-test-tool", "permission denied: /gate/test/path", %{})

    :timer.sleep(50)

    rows = error_pattern_rows()
    assert length(rows) >= 1, "VIGIL-classified failures must still become patterns"

    row = hd(rows)
    assert row.category == "io_error"
    assert row.description =~ "io_error/permission_denied in gate-test-tool"
  end
end
