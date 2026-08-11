defmodule OptimalSystemAgent.Agent.FleetResultOrderTest do
  @moduledoc """
  A fan-out's results must come back in the caller's order, and every one of
  them must name the node it is about.

  `Task.async_stream(ordered: false)` yields in COMPLETION order and the drain
  returned that as-is, so `Fleet.Finalizer`'s claim table and its conflict
  briefs — diagnostics a human reads and compares between runs — listed the
  same wave's nodes in a different order every time.

  Worse, a task reaped by the outer backstop yields a bare `{:exit, reason}`
  carrying no index, and the drain turned that into a result with an EMPTY
  `node_id`. The finalizer was then handed a failed node it could not name.

  `Orchestrator.run_parallel/3` already solves the ordering half with an
  `original_idx` it re-sorts on; this asserts the fan-out matches it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Fleet

  setup do
    prev_effort = Application.get_env(:optimal_system_agent, :effort_level)
    Effort.set(:ultra)

    on_exit(fn ->
      case prev_effort do
        nil -> Application.delete_env(:optimal_system_agent, :effort_level)
        v -> Application.put_env(:optimal_system_agent, :effort_level, v)
      end
    end)

    {:ok, parent: "order_parent_#{System.unique_integer([:positive])}"}
  end

  # Seams: no real loops, no real worktrees, no real budget rollup.
  defp opts(spawn_fun) do
    [
      spawn_fun: spawn_fun,
      budget_fun: fn _ -> false end,
      await_fun: fn _ -> :completed end,
      diff_fun: fn _ -> [] end
    ]
  end

  describe "results come back in submission order" do
    test "a node that finishes LAST still appears in its submitted position", %{parent: parent} do
      items = for n <- 1..6, do: [task: "item-#{n}"]

      # item-1 is deliberately the slowest, so completion order is the exact
      # reverse of submission order for the first two slots.
      spawn_fun = fn _parent, o ->
        task = Keyword.get(o, :task)
        if task == "item-1", do: Process.sleep(120)
        {:ok, task}
      end

      {:ok, %{results: results}} = Fleet.fan_out(parent, items, opts(spawn_fun))

      assert Enum.map(results, & &1.node_id) == [
               "item-1",
               "item-2",
               "item-3",
               "item-4",
               "item-5",
               "item-6"
             ]
    end

    test "the order is stable across repeated identical runs", %{parent: parent} do
      items = for n <- 1..8, do: [task: "n#{n}"]

      spawn_fun = fn _parent, o ->
        # Jittered completion: without an index the yield order is genuinely
        # nondeterministic between runs.
        Process.sleep(:rand.uniform(20))
        {:ok, Keyword.get(o, :task)}
      end

      orders =
        for _ <- 1..5 do
          {:ok, %{results: results}} = Fleet.fan_out(parent, items, opts(spawn_fun))
          Enum.map(results, & &1.node_id)
        end

      assert Enum.uniq(orders) |> length() == 1,
             "the same wave reported its nodes in a different order between runs"

      assert hd(orders) == Enum.map(items, &Keyword.get(&1, :task))
    end

    test "results count always matches the submitted item count", %{parent: parent} do
      items = for n <- 1..5, do: [task: "c#{n}"]
      spawn_fun = fn _p, o -> {:ok, Keyword.get(o, :task)} end

      {:ok, %{total: total, results: results}} = Fleet.fan_out(parent, items, opts(spawn_fun))

      assert total == 5
      assert length(results) == 5
    end
  end

  describe "a reaped node keeps its identity" do
    test "a task killed by the outer backstop is still named", %{parent: parent} do
      prev = Application.get_env(:optimal_system_agent, :node_timeout_ms)
      # Squeeze the outer backstop so the reap is the observable.
      Application.put_env(:optimal_system_agent, :node_timeout_ms, 60)
      on_exit(fn -> restore(:node_timeout_ms, prev) end)

      items = [[task: "fast-a"], [task: "wedged-b"], [task: "fast-c"]]

      spawn_fun = fn _parent, o ->
        if Keyword.get(o, :task) == "wedged-b", do: Process.sleep(60_000)
        {:ok, Keyword.get(o, :task)}
      end

      {:ok, %{results: results}} = Fleet.fan_out(parent, items, opts(spawn_fun))

      assert length(results) == 3
      assert Enum.map(results, & &1.node_id) == ["fast-a", "wedged-b", "fast-c"]

      reaped = Enum.at(results, 1)

      assert reaped.gate == :fail

      refute reaped.node_id == "",
             "a reaped node came back with an empty node_id — the finalizer cannot name it"
    end
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)
end
