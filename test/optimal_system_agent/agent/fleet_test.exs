defmodule OptimalSystemAgent.Agent.FleetTest do
  @moduledoc """
  FleetView B2 — global fleet cap (spawn-bomb protection) + agent-type
  system-prompt/tool resolution. These do NOT boot real loops; they exercise the
  pure guard + resolution logic against a seeded RunStore.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Fleet
  alias OptimalSystemAgent.Agent.RunStore

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_fleet_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prev_runs = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    prev_cap = Application.get_env(:optimal_system_agent, :max_fleet_agents)
    prev_total = Application.get_env(:optimal_system_agent, :max_fleet_total)
    prev_node_timeout = Application.get_env(:optimal_system_agent, :node_timeout_ms)
    prev_effort = Application.get_env(:optimal_system_agent, :effort_level)
    prev_session_effort = session_effort_level()
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)
    # Fan-out is ultra-gated; default tests to a sub-ultra tier so the gate is
    # exercised unless a test explicitly raises to ultra.
    Effort.set(:high)

    on_exit(fn ->
      restore_env(:agent_runs_dir, prev_runs)
      restore_env(:max_fleet_agents, prev_cap)
      restore_env(:max_fleet_total, prev_total)
      restore_env(:node_timeout_ms, prev_node_timeout)
      restore_env(:effort_level, prev_effort)
      restore_session_effort_level(prev_session_effort)
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp session_effort_level do
    case :ets.whereis(:osa_settings) do
      :undefined ->
        :missing

      _ ->
        case :ets.lookup(:osa_settings, {:session, :effort_level}) do
          [{{:session, :effort_level}, value}] -> {:value, value}
          _ -> :missing
        end
    end
  end

  defp restore_session_effort_level(:missing) do
    if :ets.whereis(:osa_settings) != :undefined,
      do: :ets.delete(:osa_settings, {:session, :effort_level})
  end

  defp restore_session_effort_level({:value, value}) do
    if :ets.whereis(:osa_settings) != :undefined,
      do: :ets.insert(:osa_settings, {{:session, :effort_level}, value})
  end

  defp seed_running(n, parent) do
    Enum.each(1..n, fn i ->
      RunStore.start_run(%{
        agent_id: "fleet-seed-#{parent}-#{i}-#{System.unique_integer([:positive])}",
        parent_session_id: parent,
        role: "general-purpose",
        task: "seed"
      })
    end)
  end

  describe "max_fleet_agents/0" do
    test "defaults to 16 and is configurable" do
      Application.delete_env(:optimal_system_agent, :max_fleet_agents)
      assert Fleet.max_fleet_agents() == 16

      Application.put_env(:optimal_system_agent, :max_fleet_agents, 4)
      assert Fleet.max_fleet_agents() == 4
    end
  end

  describe "spawn_fleet_node/2 fleet cap" do
    test "refuses to spawn when the running fleet is at capacity" do
      parent = "parent-#{System.unique_integer([:positive])}"
      Application.put_env(:optimal_system_agent, :max_fleet_agents, 2)
      seed_running(2, parent)

      assert {:error, {:fleet_cap_reached, running, cap}} =
               Fleet.spawn_fleet_node(parent, agent_type: "general-purpose", task: "hi")

      assert cap == 2
      assert running >= 2
    end

    test "rejects a non-binary parent id" do
      assert {:error, :invalid_parent_session_id} = Fleet.spawn_fleet_node(nil)
    end
  end

  describe "resolve_agent_type/2" do
    test "explicit system_prompt override wins and imposes no tool allowlist" do
      assert {"custom prompt", nil} = Fleet.resolve_agent_type("code-reviewer", "custom prompt")
    end

    test "built-in general-purpose fallback has full tools (nil allowlist)" do
      # Assumes no AGENT.md 'general-purpose' overrides in this env; falls through
      # to the built-in table.
      {prompt, tools} = Fleet.resolve_agent_type("general-purpose")
      assert is_binary(prompt)
      assert tools == nil
    end

    test "built-in code-reviewer fallback is restricted to read-only tools" do
      case OptimalSystemAgent.Agents.Registry.get("code-reviewer") do
        nil ->
          {prompt, tools} = Fleet.resolve_agent_type("code-reviewer")
          assert is_binary(prompt)
          assert is_list(tools)
          refute "file_write" in tools

        _def ->
          # A project/user AGENT.md defines code-reviewer — resolution still works.
          {prompt, _tools} = Fleet.resolve_agent_type("code-reviewer")
          assert prompt == nil or is_binary(prompt)
      end
    end

    test "an unknown agent-type resolves to {nil, nil}" do
      assert {nil, nil} = Fleet.resolve_agent_type("no-such-type-xyz")
    end
  end

  describe "fan_out/3 ultra gate" do
    test "refuses below the ultra effort tier" do
      Effort.set(:high)
      parent = "parent-#{System.unique_integer([:positive])}"
      assert {:error, :ultra_required} = Fleet.fan_out(parent, ["a", "b"], spawn_fun: fake_spawn())
    end

    test "even :max is not enough — ultra is required" do
      Effort.set(:max)
      parent = "parent-#{System.unique_integer([:positive])}"
      assert {:error, :ultra_required} = Fleet.fan_out(parent, ["a"], spawn_fun: fake_spawn())
    end

    test "rejects a non-binary parent id regardless of effort" do
      Effort.set(:ultra)
      assert {:error, :invalid_parent_session_id} = Fleet.fan_out(nil, ["a"])
    end
  end

  describe "fan_out/3 queue-drain (ultra)" do
    setup do
      Effort.set(:ultra)
      :ok
    end

    test "runs every item, bounded by max_fleet_agents, and never refuses past cap" do
      Application.put_env(:optimal_system_agent, :max_fleet_agents, 2)
      parent = "parent-#{System.unique_integer([:positive])}"

      # Track peak concurrency to prove the pool is bounded (not fire-all-at-once).
      {:ok, peak} = Agent.start_link(fn -> {0, 0} end)

      spawn_fun = fn _p, opts ->
        Agent.update(peak, fn {cur, mx} -> {cur + 1, max(cur + 1, mx)} end)
        Process.sleep(15)
        Agent.update(peak, fn {cur, mx} -> {cur - 1, mx} end)
        {:ok, Keyword.get(opts, :task)}
      end

      items = for i <- 1..6, do: "task-#{i}"
      assert {:ok, %{total: 6, dropped: 0, results: results}} =
               Fleet.fan_out(parent, items, spawn_fun: spawn_fun)

      # All 6 drained; the queue never fails an item.
      assert length(results) == 6
      assert Enum.all?(results, &match?({:ok, _}, &1))

      {_cur, mx} = Agent.get(peak, & &1)
      Agent.stop(peak)
      # Concurrency stayed within the cap (2), proving FIFO queue-drain not
      # spawn-all-at-once.
      assert mx <= 2
    end

    test "the run-lifetime kill switch (:max_fleet_total) drops excess items" do
      Application.put_env(:optimal_system_agent, :max_fleet_agents, 4)
      Application.put_env(:optimal_system_agent, :max_fleet_total, 3)
      parent = "parent-#{System.unique_integer([:positive])}"

      items = for i <- 1..10, do: "task-#{i}"
      assert {:ok, %{total: 3, dropped: 7, results: results}} =
               Fleet.fan_out(parent, items, spawn_fun: fake_spawn())

      assert length(results) == 3
    end

    test "emits a live fleet_summary at start and on each completion" do
      Application.put_env(:optimal_system_agent, :max_fleet_agents, 4)
      parent = "parent-summary-#{System.unique_integer([:positive])}"
      test_pid = self()

      ref =
        OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn payload ->
          data = if is_map(payload[:data]), do: payload[:data], else: payload

          if (data[:event] || data["event"]) == "fleet_summary" and
               (data[:session_id] || data["session_id"]) == parent do
            send(test_pid, {:summary, data})
          end
        end)

      items = for i <- 1..3, do: "task-#{i}"
      assert {:ok, %{total: 3}} = Fleet.fan_out(parent, items, spawn_fun: fake_spawn())

      # start (spawned 0) + one per completion (3) = 4 emissions.
      summaries = collect_summaries([])
      OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, ref)

      assert length(summaries) >= 4
      spawned = Enum.map(summaries, & &1[:total_spawned]) |> Enum.sort()
      assert List.first(spawned) == 0
      assert List.last(spawned) == 3
      # Every summary carries the cap + warn fields the header needs.
      assert Enum.all?(summaries, fn s -> s[:cap] == 4 and is_boolean(s[:warn]) end)
    end

    test "seeds the shared scratchpad with a workflow header at start" do
      parent = "parent-seed-#{System.unique_integer([:positive])}"
      test_pid = self()

      ref =
        OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn payload ->
          data = if is_map(payload[:data]), do: payload[:data], else: payload

          if (data[:event] || data["event"]) == :scratchpad_activity and
               (data[:agent] || data["agent"]) == "fleet-workflow" do
            send(test_pid, {:seeded, data})
          end
        end)

      assert {:ok, %{total: 2}} =
               Fleet.fan_out(parent, ["a", "b"], spawn_fun: fake_spawn(), task: "big goal")

      # The workflow header was published to the shared scratchpad (best-effort,
      # but here it must succeed) so orchestrated nodes share a workspace.
      assert_receive {:seeded, data}, 1_000
      assert data[:entry] == "workflow.md"

      OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, ref)

      # And the entry is actually readable in the shared session-root scratchpad.
      id = OptimalSystemAgent.Scratchpad.session_root(parent)
      assert {:ok, content} = OptimalSystemAgent.Scratchpad.read(id, "workflow.md")
      assert content =~ "Dynamic workflow"
      assert content =~ "big goal"
    end
  end

  describe "node_timeout_ms/0" do
    test "defaults to 5 minutes and is configurable" do
      Application.delete_env(:optimal_system_agent, :node_timeout_ms)
      assert Fleet.node_timeout_ms() == 300_000

      Application.put_env(:optimal_system_agent, :node_timeout_ms, 50)
      assert Fleet.node_timeout_ms() == 50
    end
  end

  describe "fan_out/3 edge cases (ultra)" do
    setup do
      Effort.set(:ultra)
      :ok
    end

    test "empty items is a no-op — {:ok, total: 0} with no crash" do
      parent = "parent-empty-#{System.unique_integer([:positive])}"

      assert {:ok, %{total: 0, dropped: 0, results: []}} =
               Fleet.fan_out(parent, [], spawn_fun: fake_spawn())
    end

    test "a single item runs" do
      parent = "parent-single-#{System.unique_integer([:positive])}"

      assert {:ok, %{total: 1, dropped: 0, results: [{:ok, "only"}]}} =
               Fleet.fan_out(parent, ["only"], spawn_fun: fake_spawn())
    end

    test "a huge batch past :max_fleet_total truncates and reports dropped" do
      Application.put_env(:optimal_system_agent, :max_fleet_agents, 8)
      Application.put_env(:optimal_system_agent, :max_fleet_total, 5)
      parent = "parent-huge-#{System.unique_integer([:positive])}"

      items = for i <- 1..50, do: "task-#{i}"

      assert {:ok, %{total: 5, dropped: 45, results: results}} =
               Fleet.fan_out(parent, items, spawn_fun: fake_spawn())

      assert length(results) == 5
    end
  end

  describe "fan_out/3 node error isolation (ultra)" do
    setup do
      Effort.set(:ultra)
      :ok
    end

    test "one raising node does not kill the workflow — it becomes an error result" do
      Application.put_env(:optimal_system_agent, :max_fleet_agents, 4)
      parent = "parent-iso-#{System.unique_integer([:positive])}"

      spawn_fun = fn _p, opts ->
        case Keyword.get(opts, :task) do
          "boom" -> raise "kaboom"
          other -> {:ok, other}
        end
      end

      items = ["a", "boom", "b", "c"]

      assert {:ok, %{total: 4, dropped: 0, results: results}} =
               Fleet.fan_out(parent, items, spawn_fun: spawn_fun)

      # Every item produced a result — none aborted the drain.
      assert length(results) == 4
      # The good ones succeeded; the bad one is isolated as an error result.
      assert Enum.count(results, &match?({:ok, _}, &1)) == 3
      assert Enum.any?(results, &match?({:error, {:node_error, _}}, &1))
    end

    test "a throwing node is isolated too and the rest still drain" do
      Application.put_env(:optimal_system_agent, :max_fleet_agents, 4)
      parent = "parent-throw-#{System.unique_integer([:positive])}"

      spawn_fun = fn _p, opts ->
        case Keyword.get(opts, :task) do
          "throw" -> throw(:nope)
          other -> {:ok, other}
        end
      end

      assert {:ok, %{total: 3, results: results}} =
               Fleet.fan_out(parent, ["x", "throw", "y"], spawn_fun: spawn_fun)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 2
      assert Enum.any?(results, &match?({:error, {:node_throw, :nope}}, &1))
    end
  end

  describe "fan_out/3 per-node timeout (ultra)" do
    setup do
      Effort.set(:ultra)
      :ok
    end

    test "a hung node is reaped as a timed-out result and the others complete" do
      Application.put_env(:optimal_system_agent, :max_fleet_agents, 4)
      # Tight per-node ceiling so the slow node is reaped quickly.
      Application.put_env(:optimal_system_agent, :node_timeout_ms, 80)
      parent = "parent-timeout-#{System.unique_integer([:positive])}"

      spawn_fun = fn _p, opts ->
        case Keyword.get(opts, :task) do
          "hang" ->
            Process.sleep(5_000)
            {:ok, "should-never-return"}

          other ->
            {:ok, other}
        end
      end

      items = ["fast1", "hang", "fast2", "fast3"]

      assert {:ok, %{total: 4, results: results}} =
               Fleet.fan_out(parent, items, spawn_fun: spawn_fun)

      assert length(results) == 4
      # The hung node was reaped; the three fast nodes still completed.
      assert Enum.count(results, &match?({:ok, _}, &1)) == 3
      assert {:error, :node_timeout} in results
    end
  end

  describe "fan_out/3 effort gate is entry-only (ultra)" do
    test "a workflow started at :ultra keeps running if effort drops mid-flight" do
      Effort.set(:ultra)
      Application.put_env(:optimal_system_agent, :max_fleet_agents, 2)
      parent = "parent-effortdrop-#{System.unique_integer([:positive])}"

      # The first node to run lowers the effort tier below ultra. Because the
      # gate is checked ONCE at entry (not per item), every item must still run.
      spawn_fun = fn _p, opts ->
        Effort.set(:high)
        {:ok, Keyword.get(opts, :task)}
      end

      items = for i <- 1..5, do: "task-#{i}"

      assert {:ok, %{total: 5, dropped: 0, results: results}} =
               Fleet.fan_out(parent, items, spawn_fun: spawn_fun)

      assert length(results) == 5
      assert Enum.all?(results, &match?({:ok, _}, &1))
      # Effort really was dropped mid-flight, yet the workflow completed.
      refute Effort.current_at_least?(:ultra)
    end
  end

  defp fake_spawn do
    fn _parent, opts -> {:ok, Keyword.get(opts, :task, "done")} end
  end

  defp collect_summaries(acc) do
    receive do
      {:summary, data} -> collect_summaries([data | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end
end
