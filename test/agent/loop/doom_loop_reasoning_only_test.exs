defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.ReasoningOnlyTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.DoomLoop
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Resample

  defp base_state do
    %{
      session_id: "test-reasoning-only",
      total_tool_calls: 0,
      recent_failure_signatures: [],
      messages: []
    }
  end

  describe "check/3 — reasoning-only spin (no tool calls)" do
    test "does not trip on the first couple of empty-tool-call turns" do
      assert {:ok, state} = DoomLoop.check([], [], base_state())
      assert state.reasoning_only_streak == 1

      assert {:ok, state} = DoomLoop.check([], [], state)
      assert state.reasoning_only_streak == 2
    end

    test "trips at the configured threshold (default 3) and halts" do
      state = base_state()
      {:ok, state} = DoomLoop.check([], [], state)
      {:ok, state} = DoomLoop.check([], [], state)

      assert {:halt, msg, halted_state} = DoomLoop.check([], [], state)
      assert msg =~ "reasoning-only"
      assert halted_state.reasoning_only_streak == 0
    end

    test "a tool call in between resets the streak" do
      state = base_state()
      {:ok, state} = DoomLoop.check([], [], state)
      {:ok, state} = DoomLoop.check([], [], state)

      tc = %{id: "c1", name: "file_read", arguments: %{"path" => "x"}}
      result = {%{role: "tool", tool_call_id: "c1", content: "ok"}, "ok"}

      assert {:ok, state} = DoomLoop.check([{tc, result}], [tc], state)
      assert state.reasoning_only_streak == 0

      # Back to reasoning-only afterward starts counting from zero again.
      assert {:ok, state} = DoomLoop.check([], [], state)
      assert state.reasoning_only_streak == 1
    end
  end

  describe "check/3 — turn-errored (caller-flagged) spin" do
    test "state.turn_errored counts toward the streak even with an attempted tool call" do
      tc = %{id: "c1", name: "shell_execute", arguments: %{"command" => "x"}}
      result = {%{role: "tool", tool_call_id: "c1", content: "Error: boom"}, "Error: boom"}

      state = Map.put(base_state(), :turn_errored, true)
      {:ok, state} = DoomLoop.check([{tc, result}], [tc], state)
      assert state.reasoning_only_streak == 1

      state = Map.put(state, :turn_errored, true)
      {:ok, state} = DoomLoop.check([{tc, result}], [tc], state)
      assert state.reasoning_only_streak == 2

      state = Map.put(state, :turn_errored, true)
      assert {:halt, msg, _state} = DoomLoop.check([{tc, result}], [tc], state)
      assert msg =~ "kept erroring"
    end

    test "the turn_errored flag is one-shot — cleared after each check even without tripping" do
      state = Map.put(base_state(), :turn_errored, true)
      {:ok, state} = DoomLoop.check([], [], state)
      refute state.turn_errored
    end
  end

  describe "hand-off to the existing Resample remedy" do
    test "a reasoning-only halt is resampled exactly like any other doom-loop halt" do
      put_resample_config(enabled: true, max_retries: 2, backoff_ms: 0)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :doom_loop_resample) end)

      state = base_state()
      {:ok, state} = DoomLoop.check([], [], state)
      {:ok, state} = DoomLoop.check([], [], state)
      assert {:halt, doom_message, halted_state} = DoomLoop.check([], [], state)

      snapshot = Map.put(base_state(), :doom_resamples, 0)
      test_pid = self()

      run_fun = fn retry_state ->
        send(test_pid, {:resampled, retry_state})
        {"recovered", retry_state}
      end

      assert {"recovered", final} = Resample.handle(doom_message, halted_state, snapshot, run_fun)
      assert_received {:resampled, _retry_state}
      assert final.doom_resamples == 1
    end
  end

  defp put_resample_config(kw),
    do: Application.put_env(:optimal_system_agent, :doom_loop_resample, kw)
end
