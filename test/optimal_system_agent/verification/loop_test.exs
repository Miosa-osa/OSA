defmodule OptimalSystemAgent.Verification.LoopTest do
  @moduledoc """
  Regression coverage for the verification loop's test-result plumbing.

  The loop used to `send/2` its result as `{self(), {:test_result, ...}}` while
  the receiving clause required `{ref, {:test_result, ...}} when is_reference(ref)`.
  A pid is not a reference, so every result fell through to the catch-all, the
  task's NORMAL exit was then read as a crash, and `passed = exit_code == 0` was
  false on every single iteration — `succeed/1` was unreachable and every run
  ended in `escalate(state, :max_iterations_reached)` plus an algedonic alert.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Verification.Loop

  # Poll the loop's snapshot until it leaves `:running`, or give up.
  defp await_terminal(loop_id, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_terminal(loop_id, deadline)
  end

  defp do_await_terminal(loop_id, deadline) do
    case Loop.get_state(loop_id) do
      {:ok, %{status: status} = snap} when status != :running ->
        {:ok, snap}

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, other}
        else
          Process.sleep(25)
          do_await_terminal(loop_id, deadline)
        end
    end
  end

  describe "test result delivery" do
    test "a passing test command reaches :passed on the first iteration" do
      loop_id = "vloop-pass-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Loop.start_link(
          loop_id: loop_id,
          test_command: "exit 0",
          max_iterations: 2,
          timeout_ms: 30_000
        )

      assert {:ok, snap} = await_terminal(loop_id)
      assert snap.status == :passed
      assert snap.iteration == 1
    end

    test "a failing test command still escalates at the iteration limit" do
      loop_id = "vloop-fail-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Loop.start_link(
          loop_id: loop_id,
          test_command: "exit 3",
          max_iterations: 1,
          timeout_ms: 30_000
        )

      assert {:ok, snap} = await_terminal(loop_id)
      assert snap.status == :escalated
      assert snap.iteration == 1
    end
  end
end
