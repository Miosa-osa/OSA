defmodule OptimalSystemAgent.Agent.Loop.DurableLogTest do
  @moduledoc """
  Crash-recovery / durable-execution tests for primitive #27.

  Each test drives a real per-session JSONL log under an isolated tmp dir, then
  simulates a mid-turn "crash" by dropping all in-memory state (the log file is
  the ONLY thing that survives) and asserts that already-completed steps are NOT
  re-executed on resume.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.DurableLog
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor

  setup do
    # Isolate every test in its own durable dir and force the feature on.
    dir = Path.join(System.tmp_dir!(), "osa-durable-test-#{System.unique_integer([:positive])}")
    prev_dir = Application.get_env(:optimal_system_agent, :durable_log_dir)
    prev_enabled = Application.get_env(:optimal_system_agent, :durable_execution)

    Application.put_env(:optimal_system_agent, :durable_log_dir, dir)
    Application.put_env(:optimal_system_agent, :durable_execution, true)

    on_exit(fn ->
      File.rm_rf(dir)
      restore_env(:durable_log_dir, prev_dir)
      restore_env(:durable_execution, prev_enabled)
    end)

    session_id = "durable-test-#{System.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  # A tool step result in the loop's `{tool_msg, result_str}` contract.
  defp step_result(tool_call, body) do
    {%{role: "tool", tool_call_id: tool_call.id, name: tool_call.name, content: body}, body}
  end

  describe "step_key/2" do
    test "is stable across a crash+resume (independent of the provider tool_call.id)" do
      state = %{session_id: "s", turn_count: 3, iteration: 5}

      before_crash = %{
        id: "call_AAA",
        name: "file_write",
        arguments: %{"path" => "/x", "content" => "hi"}
      }

      after_resume = %{
        id: "call_ZZZ",
        name: "file_write",
        arguments: %{"content" => "hi", "path" => "/x"}
      }

      # Different provider ids, different key ordering — same logical step.
      assert DurableLog.step_key(state, before_crash) == DurableLog.step_key(state, after_resume)
    end

    test "differs by tool name, arguments, iteration and turn" do
      base_state = %{session_id: "s", turn_count: 1, iteration: 1}
      tc = %{id: "1", name: "shell_execute", arguments: %{"command" => "ls"}}
      k = DurableLog.step_key(base_state, tc)

      refute k == DurableLog.step_key(base_state, %{tc | name: "file_read"})
      refute k == DurableLog.step_key(base_state, %{tc | arguments: %{"command" => "rm -rf /"}})
      refute k == DurableLog.step_key(%{base_state | iteration: 2}, tc)
      refute k == DurableLog.step_key(%{base_state | turn_count: 2}, tc)
    end
  end

  describe "record/load/completed?" do
    test "records a completed step and reports it as completed", %{session_id: sid} do
      tc = %{id: "1", name: "file_write", arguments: %{"path" => "/a"}}
      key = "t0-i0-file_write-abc"

      refute DurableLog.completed?(sid, key)
      DurableLog.record(sid, key, tc, %{content: "wrote /a"}, "wrote /a")

      assert DurableLog.completed?(sid, key)
      assert DurableLog.step_count(sid) == 1
      assert %{^key => %{result: "wrote /a", content: "wrote /a"}} = DurableLog.load(sid)
    end

    test "load survives a torn final line (crash-safe append log)", %{session_id: sid} do
      DurableLog.record(sid, "k1", %{name: "t"}, %{content: "one"}, "one")
      DurableLog.record(sid, "k2", %{name: "t"}, %{content: "two"}, "two")
      # Simulate a crash mid-write: the process died leaving a half-written final
      # JSON line (no trailing newline, truncated). This is always the LAST line.
      File.write!(DurableLog.log_path(sid), ~s({"key":"k3","result":"thr), [:append])

      loaded = DurableLog.load(sid)
      # Earlier complete steps survive; the torn final step is skipped.
      assert Map.has_key?(loaded, "k1")
      assert Map.has_key?(loaded, "k2")
      refute Map.has_key?(loaded, "k3")
    end

    test "clear/1 removes the log", %{session_id: sid} do
      DurableLog.record(sid, "k", %{name: "t"}, %{content: "x"}, "x")
      assert DurableLog.step_count(sid) == 1
      DurableLog.clear(sid)
      assert DurableLog.step_count(sid) == 0
    end
  end

  describe "run_once/3 — idempotency across a simulated crash" do
    test "a completed step is NOT re-executed after a crash; recorded result replays",
         %{session_id: sid} do
      # Observable side effect: bump an ETS counter each real execution.
      table = :ets.new(:durable_side_effect, [:public])
      :ets.insert(table, {:runs, 0})

      state = %{session_id: sid, turn_count: 1, iteration: 2}
      tool_call = %{id: "call_1", name: "shell_execute", arguments: %{"command" => "deploy"}}

      run_step = fn tc ->
        DurableLog.run_once(state, tc, fn ->
          :ets.update_counter(table, :runs, 1)
          step_result(tc, "deployed")
        end)
      end

      # --- Original execution (pre-crash) ---
      {msg1, result1} = run_step.(tool_call)
      assert result1 == "deployed"
      assert msg1.tool_call_id == "call_1"
      assert [{:runs, 1}] = :ets.lookup(table, :runs)

      # --- CRASH: drop all in-memory state. Only the durable log file survives.
      # Resume re-issues the SAME logical tool call but with a fresh provider id.
      resumed_tool_call = %{tool_call | id: "call_RESUMED"}

      {msg2, result2} = run_step.(resumed_tool_call)

      # Side effect did NOT run a second time — the recorded result replayed.
      assert [{:runs, 1}] = :ets.lookup(table, :runs)
      assert result2 == "deployed"
      # Replayed message is bound to the CURRENT (resumed) tool_call id.
      assert msg2.tool_call_id == "call_RESUMED"
      assert msg2.content == "deployed"
    end

    test "distinct steps in the same turn each run exactly once", %{session_id: sid} do
      table = :ets.new(:durable_multi, [:public])
      state = %{session_id: sid, turn_count: 1, iteration: 1}

      calls = [
        %{id: "a", name: "file_write", arguments: %{"path" => "/1"}},
        %{id: "b", name: "file_write", arguments: %{"path" => "/2"}},
        %{id: "c", name: "shell_execute", arguments: %{"command" => "ls"}}
      ]

      run_all = fn ->
        Enum.map(calls, fn tc ->
          DurableLog.run_once(state, tc, fn ->
            :ets.update_counter(table, tc.id, 1, {tc.id, 0})
            step_result(tc, "ok:#{tc.id}")
          end)
        end)
      end

      run_all.()
      # Simulate crash + full resume of the batch.
      results = run_all.()

      # Every step ran exactly once despite the batch being re-issued.
      for tc <- calls, do: assert(:ets.lookup(table, tc.id) == [{tc.id, 1}])
      assert Enum.map(results, fn {_m, r} -> r end) == ["ok:a", "ok:b", "ok:c"]
    end

    test "failed steps are NOT recorded and DO re-run on resume", %{session_id: sid} do
      table = :ets.new(:durable_fail, [:public])
      :ets.insert(table, {:runs, 0})
      state = %{session_id: sid, turn_count: 1, iteration: 1}
      tc = %{id: "1", name: "shell_execute", arguments: %{"command" => "flaky"}}

      run_step = fn ->
        DurableLog.run_once(state, tc, fn ->
          n = :ets.update_counter(table, :runs, 1)
          # First attempt fails, second succeeds (transient error).
          if n == 1, do: step_result(tc, "Error: transient"), else: step_result(tc, "ok")
        end)
      end

      {_m, r1} = run_step.()
      assert r1 == "Error: transient"
      refute DurableLog.completed?(sid, DurableLog.step_key(state, tc))

      # Resume: the failed step is retried (not deduped) and now succeeds.
      {_m, r2} = run_step.()
      assert r2 == "ok"
      assert [{:runs, 2}] = :ets.lookup(table, :runs)
      # The successful attempt is now recorded — a further resume would dedup it.
      assert DurableLog.completed?(sid, DurableLog.step_key(state, tc))
    end

    test "when disabled, run_once is a pure passthrough (no dedup, no writes)", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :durable_execution, false)
      table = :ets.new(:durable_off, [:public])
      :ets.insert(table, {:runs, 0})
      state = %{session_id: sid, turn_count: 1, iteration: 1}
      tc = %{id: "1", name: "shell_execute", arguments: %{"command" => "x"}}

      run = fn ->
        DurableLog.run_once(state, tc, fn ->
          :ets.update_counter(table, :runs, 1)
          step_result(tc, "ran")
        end)
      end

      run.()
      run.()

      # No dedup: ran twice; and nothing was persisted.
      assert [{:runs, 2}] = :ets.lookup(table, :runs)
      assert DurableLog.step_count(sid) == 0
    end

    test "ToolExecutor.execute_tool_call replays a recorded step without touching the tool stack",
         %{session_id: sid} do
      # Proves the wiring in ToolExecutor.execute_tool_call/2: a pre-recorded
      # step short-circuits BEFORE approval/validation/dispatch. If the wrapper
      # were absent, this unknown tool would run through the registry and come
      # back as an "Error:" instead of the recorded result.
      state = %{session_id: sid, turn_count: 0, iteration: 0, permission_tier: :full}
      tool_call = %{id: "live_id", name: "nonexistent_tool_xyz", arguments: %{"k" => "v"}}

      key = DurableLog.step_key(state, tool_call)
      DurableLog.record(sid, key, tool_call, %{content: "recorded-output"}, "recorded-output")

      {msg, result} = ToolExecutor.execute_tool_call(tool_call, state)

      assert result == "recorded-output"
      assert msg.tool_call_id == "live_id"
      assert msg.content == "recorded-output"
    end

    test "session-less state passes through without touching disk" do
      table = :ets.new(:durable_nosession, [:public])
      :ets.insert(table, {:runs, 0})
      tc = %{id: "1", name: "t", arguments: %{}}

      Enum.each(1..2, fn _ ->
        DurableLog.run_once(%{turn_count: 1, iteration: 1}, tc, fn ->
          :ets.update_counter(table, :runs, 1)
          step_result(tc, "ran")
        end)
      end)

      assert [{:runs, 2}] = :ets.lookup(table, :runs)
    end
  end
end
