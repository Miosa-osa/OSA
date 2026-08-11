defmodule OptimalSystemAgent.Agent.HooksETSTest do
  @moduledoc """
  Tests for the ETS-based hook execution architecture.

  Verifies that:
    1. Hooks are stored in ETS table :osa_hooks
    2. Registration writes to ETS via GenServer
    3. Execution reads from ETS in the caller's process (no GenServer call)
    4. Hook chain runs correctly (passthrough, blocking, crash isolation)
    5. API surface is identical to the original GenServer-only implementation
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Hooks

  setup do
    case Process.whereis(Hooks) do
      nil ->
        {:ok, %{available: false}}

      _pid ->
        # Remove any hook this test registers into the global ETS table on exit
        # so a leaked {:block,…} hook never contaminates other tests.
        baseline = hook_key_set()

        on_exit(fn ->
          for {event, name} <- MapSet.difference(hook_key_set(), baseline) do
            Hooks.unregister(event, name)
          end
        end)

        {:ok, %{available: true}}
    end
  end

  defp hook_key_set do
    Hooks.list_hooks()
    |> Enum.flat_map(fn {event, hooks} -> Enum.map(hooks, &{event, &1.name}) end)
    |> MapSet.new()
  end

  # ── ETS Table Existence ─────────────────────────────────────────

  describe "ETS table :osa_hooks" do
    @tag :hooks_ets
    test "ETS table exists and is accessible", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      table = Hooks.hooks_table_name()

      assert :ets.whereis(table) != :undefined,
             "ETS table #{inspect(table)} should exist"
    end

    @tag :hooks_ets
    test "ETS table is a bag with read_concurrency", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      table = Hooks.hooks_table_name()
      info = :ets.info(table)

      assert Keyword.get(info, :type) == :bag,
             "ETS table should be of type :bag"

      assert Keyword.get(info, :read_concurrency) == true,
             "ETS table should have read_concurrency enabled"
    end

    @tag :hooks_ets
    test "ETS table is public (readable from any process)", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      table = Hooks.hooks_table_name()
      info = :ets.info(table)

      assert Keyword.get(info, :protection) == :public,
             "ETS table should be public for caller-process reads"
    end
  end

  # ── Registration via GenServer → ETS ────────────────────────────

  describe "registration stores hooks in ETS" do
    @tag :hooks_ets
    test "register/4 inserts hook entry into ETS", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      hook_name = "ets_test_hook_#{System.unique_integer([:positive])}"
      hook_fn = fn payload -> {:ok, payload} end

      :ok = Hooks.register(:post_response, hook_name, hook_fn, priority: 77)
      # register is a cast — give it a moment
      Process.sleep(50)

      table = Hooks.hooks_table_name()
      entries = :ets.lookup(table, :post_response)

      names = Enum.map(entries, fn {_event, name, _priority, _handler, _opts} -> name end)

      assert hook_name in names,
             "Hook #{hook_name} should appear in ETS after registration"
    end

    @tag :hooks_ets
    test "registered hook appears in list_hooks/0", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      hook_name = "ets_list_test_#{System.unique_integer([:positive])}"
      hook_fn = fn payload -> {:ok, payload} end

      :ok = Hooks.register(:session_start, hook_name, hook_fn, priority: 42)
      Process.sleep(50)

      listing = Hooks.list_hooks()
      session_hooks = Map.get(listing, :session_start, [])
      names = Enum.map(session_hooks, & &1.name)

      assert hook_name in names
    end
  end

  # ── Execution in caller process ─────────────────────────────────

  describe "run/2 executes in caller process" do
    @tag :hooks_ets
    test "run/2 returns {:ok, payload} for passthrough hooks", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      payload = %{
        tool_name: "file_read",
        arguments: %{"path" => "/tmp/test.txt"},
        session_id: "ets_test"
      }

      result = Hooks.run(:pre_tool_use, payload)

      assert {:ok, returned} = result
      assert returned.tool_name == "file_read"
    end

    @tag :hooks_ets
    test "run/2 does not go through GenServer call (caller PID executes hooks)", %{
      available: available
    } do
      if not available, do: flunk("Hooks GenServer not running")

      # Register a hook that records the executing process PID
      hook_name = "pid_tracker_#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        Hooks.register(
          :pre_compact,
          hook_name,
          fn payload ->
            send(test_pid, {:hook_executed_in, self()})
            {:ok, payload}
          end,
          priority: 50
        )

      Process.sleep(50)

      _result = Hooks.run(:pre_compact, %{session_id: "pid_test"})

      assert_receive {:hook_executed_in, executing_pid}, 1000
      # The hook should execute in the CALLER's process (self()), not the GenServer
      assert executing_pid == self(),
             "Hook should execute in caller process #{inspect(self())}, but ran in #{inspect(executing_pid)}"
    end
  end

  # ── Hook chain correctness ─────────────────────────────────────

  describe "hook chain execution" do
    @tag :hooks_ets
    test "hooks execute in priority order", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      # Use a unique event to avoid interference from built-in hooks
      execution_order = :ets.new(:exec_order, [:ordered_set, :public])
      counter = :counters.new(1, [])

      for {priority, label} <- [{10, "first"}, {50, "second"}, {90, "third"}] do
        hook_name = "order_test_#{label}_#{System.unique_integer([:positive])}"

        :ok =
          Hooks.register(
            :pre_response,
            hook_name,
            fn payload ->
              idx = :counters.get(counter, 1)
              :counters.add(counter, 1, 1)
              :ets.insert(execution_order, {idx, label})
              {:ok, payload}
            end,
            priority: priority
          )
      end

      Process.sleep(50)

      _result = Hooks.run(:pre_response, %{session_id: "order_test"})

      entries = :ets.tab2list(execution_order) |> Enum.sort()
      labels = Enum.map(entries, fn {_idx, label} -> label end)

      assert List.first(labels) == "first"
      assert List.last(labels) == "third"

      :ets.delete(execution_order)
    end

    @tag :hooks_ets
    test "blocking hook stops the chain", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      hook_name = "ets_blocker_#{System.unique_integer([:positive])}"

      :ok =
        Hooks.register(
          :pre_tool_use,
          hook_name,
          fn payload ->
            if payload.tool_name == "ets_blocked_tool" do
              {:block, "ETS test block"}
            else
              {:ok, payload}
            end
          end,
          priority: 1
        )

      Process.sleep(50)

      payload = %{tool_name: "ets_blocked_tool", arguments: %{}, session_id: "ets_block_test"}
      result = Hooks.run(:pre_tool_use, payload)

      assert {:blocked, "ETS test block"} = result
    end

    @tag :hooks_ets
    test "crashing hook does not crash the caller", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      hook_name = "ets_crasher_#{System.unique_integer([:positive])}"

      :ok =
        Hooks.register(
          :post_tool_use,
          hook_name,
          fn _payload ->
            raise "ETS crash test"
          end,
          priority: 1
        )

      Process.sleep(50)

      payload = %{tool_name: "test", result: "ok", duration_ms: 1, session_id: "ets_crash_test"}
      result = Hooks.run(:post_tool_use, payload)

      assert {:ok, _} = result
    end

    @tag :hooks_ets
    test ":skip return value skips the hook silently", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      hook_name = "ets_skipper_#{System.unique_integer([:positive])}"

      :ok =
        Hooks.register(
          :pre_response,
          hook_name,
          fn _payload ->
            :skip
          end,
          priority: 1
        )

      Process.sleep(50)

      result = Hooks.run(:pre_response, %{session_id: "skip_test"})
      assert {:ok, _} = result
    end
  end

  # ── Async execution ─────────────────────────────────────────────

  describe "run_async/2" do
    @tag :hooks_ets
    test "returns :ok immediately", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      payload = %{tool_name: "test", result: "ok", duration_ms: 1, session_id: "async_ets_test"}
      assert :ok = Hooks.run_async(:post_tool_use, payload)
    end
  end

  # ── Metrics still work ──────────────────────────────────────────

  describe "metrics" do
    @tag :hooks_ets
    test "metrics/0 returns a map after hook execution", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      # Run a hook to generate metrics
      Hooks.run(:pre_tool_use, %{
        tool_name: "file_read",
        arguments: %{},
        session_id: "metrics_ets_test"
      })

      # Metrics update is async (cast), give it a moment
      Process.sleep(100)

      metrics = Hooks.metrics()
      assert is_map(metrics)

      pre_metrics = Map.get(metrics, :pre_tool_use)

      if pre_metrics do
        assert pre_metrics.calls > 0
        assert Map.has_key?(pre_metrics, :avg_us)
      end
    end
  end

  # ── Built-in hooks in ETS ───────────────────────────────────────

  describe "built-in hooks in ETS" do
    @tag :hooks_ets
    test "all built-in hooks are present in ETS table", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      listing = Hooks.list_hooks()

      pre_names = listing |> Map.get(:pre_tool_use, []) |> Enum.map(& &1.name)
      post_names = listing |> Map.get(:post_tool_use, []) |> Enum.map(& &1.name)

      assert "security_check" in pre_names
      assert "spend_guard" in pre_names
      assert "mcp_cache" in pre_names

      assert "cost_tracker" in post_names
      assert "mcp_cache_post" in post_names
      assert "telemetry" in post_names
      assert "track_files_read" in post_names
      assert "read_before_write" in pre_names
    end
  end

  # ── Regression: track_files_read must match string result ────────
  # Bug: the hook previously matched `result: {:ok, _}` but ToolExecutor
  # normalizes tool output to a plain string before building post_payload.
  # The fix matches `result: binary` and excludes "Error:"/"Blocked:" prefixes.

  describe "track_files_read regression (string result from ToolExecutor)" do
    @tag :hooks_ets
    test "records file path when result is a plain string (success)", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      sid = "test-session-track-#{:erlang.unique_integer([:positive])}"

      # Ensure ETS table exists
      if :ets.whereis(:osa_files_read) == :undefined do
        :ets.new(:osa_files_read, [:named_table, :public, :set])
      end

      payload = %{
        tool_name: "file_read",
        arguments: %{"path" => "/tmp/some_file.ex"},
        session_id: sid,
        # Plain string — exactly what ToolExecutor provides
        result: "defmodule Foo do\nend\n"
      }

      {:ok, _updated} = Hooks.run(:post_tool_use, payload)

      # The file path must be recorded in ETS
      assert [{_, true}] = :ets.lookup(:osa_files_read, {sid, "/tmp/some_file.ex"}),
             "track_files_read should record the path when result is a success string"
    end

    @tag :hooks_ets
    test "does NOT record file path when result is an error string", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      sid = "test-session-track-err-#{:erlang.unique_integer([:positive])}"

      if :ets.whereis(:osa_files_read) == :undefined do
        :ets.new(:osa_files_read, [:named_table, :public, :set])
      end

      payload = %{
        tool_name: "file_read",
        arguments: %{"path" => "/tmp/missing.ex"},
        session_id: sid,
        result: "Error: file not found"
      }

      {:ok, _updated} = Hooks.run(:post_tool_use, payload)

      assert [] = :ets.lookup(:osa_files_read, {sid, "/tmp/missing.ex"}),
             "track_files_read must not record paths on error results"
    end

    @tag :hooks_ets
    test "does NOT record file path when result is a blocked string", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      sid = "test-session-track-block-#{:erlang.unique_integer([:positive])}"

      if :ets.whereis(:osa_files_read) == :undefined do
        :ets.new(:osa_files_read, [:named_table, :public, :set])
      end

      payload = %{
        tool_name: "file_read",
        arguments: %{"path" => "/tmp/blocked.ex"},
        session_id: sid,
        result: "Blocked: permission denied"
      }

      {:ok, _updated} = Hooks.run(:post_tool_use, payload)

      assert [] = :ets.lookup(:osa_files_read, {sid, "/tmp/blocked.ex"}),
             "track_files_read must not record paths on blocked results"
    end
  end
end
