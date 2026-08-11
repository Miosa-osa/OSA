defmodule OptimalSystemAgent.Agent.Fleet.JournalTest do
  @moduledoc """
  A coordinator crash must not lose the nodes that already finished.

  `Fleet.fan_out/3` accumulated results only in the return value of its
  `Enum.map` over the async stream — a value that lives in the coordinator
  process and nowhere else. There was no durable per-item record, no run id,
  and no resume entry point, so a crash at item 9 of 10 threw away eight
  completed agent turns whose work was already on disk.

  `Agent.FleetResumer` does not cover this: it re-dispatches orphaned
  `:running` NODES at boot via `RunStore` leases and knows nothing about a
  fan-out run, its item list, or its results. Its own moduledoc records the
  gap ("only STARTED nodes are durable").
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Fleet
  alias OptimalSystemAgent.Agent.Fleet.Journal

  setup do
    prev_effort = Application.get_env(:optimal_system_agent, :effort_level)
    Effort.set(:ultra)
    run_id = "jtest-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Journal.discard(run_id)
      File.rm(Path.join(Journal.dir(), "#{run_id}.manifest.json"))

      case prev_effort do
        nil -> Application.delete_env(:optimal_system_agent, :effort_level)
        v -> Application.put_env(:optimal_system_agent, :effort_level, v)
      end
    end)

    {:ok, run_id: run_id, parent: "jparent-#{System.unique_integer([:positive])}"}
  end

  defp opts(spawn_fun, extra \\ []) do
    Keyword.merge(
      [
        spawn_fun: spawn_fun,
        budget_fun: fn _ -> false end,
        await_fun: fn _ -> :completed end,
        diff_fun: fn _ -> [] end
      ],
      extra
    )
  end

  describe "request_hash/1" do
    test "the same item written three ways hashes alike" do
      h = Journal.request_hash("do the thing")
      assert Journal.request_hash(task: "do the thing") == h
      assert Journal.request_hash(%{"task" => "do the thing"}) == h
    end

    test "different work hashes differently" do
      refute Journal.request_hash(task: "a") == Journal.request_hash(task: "b")

      refute Journal.request_hash(task: "a", agent_type: "x") ==
               Journal.request_hash(task: "a", agent_type: "y")
    end

    test "key order does not change the hash" do
      assert Journal.request_hash(task: "a", agent_type: "x") ==
               Journal.request_hash(agent_type: "x", task: "a")
    end
  end

  describe "the journal survives the coordinator" do
    test "a crashed run's finished items are replayed, not re-executed", %{
      run_id: run_id,
      parent: parent
    } do
      items = for n <- 1..4, do: [task: "item-#{n}"]

      # Simulate a coordinator that got through items 0 and 1 before dying.
      for {item, idx} <- Enum.take(Enum.with_index(items), 2) do
        Journal.record_queued(run_id, idx, item)

        Journal.record_result(run_id, idx, item, %{
          node_id: "item-#{idx + 1}",
          worktree_ref: "wt-#{idx}",
          files_changed: ["lib/a#{idx}.ex"],
          gate: :pass,
          stubbed: [],
          summary: "completed",
          error: nil
        })
      end

      {:ok, spawned} = Agent.start_link(fn -> [] end)

      spawn_fun = fn _p, o ->
        task = Keyword.get(o, :task)
        Agent.update(spawned, &[task | &1])
        {:ok, task}
      end

      {:ok, %{results: results}} =
        Fleet.resume(parent, items, run_id, opts(spawn_fun))

      actually_spawned = Agent.get(spawned, & &1)

      assert length(results) == 4

      assert Enum.sort(actually_spawned) == ["item-3", "item-4"],
             "a completed sibling was re-executed on resume — a fan-out node is a full " <>
               "agent turn that writes to the repo"

      # The replayed halves keep their real recorded outcome, worktree ref and
      # all, so the finalizer can still merge their work.
      assert Enum.at(results, 0).node_id == "item-1"
      assert Enum.at(results, 0).worktree_ref == "wt-0"
      assert Enum.at(results, 0).files_changed == ["lib/a0.ex"]
      assert Enum.at(results, 0).gate == :pass
      assert Enum.at(results, 0).resumed == true

      # And the freshly executed ones are in their submitted positions.
      assert Enum.at(results, 2).node_id == "item-3"
      assert Enum.at(results, 3).node_id == "item-4"
    end

    test "a journalled result for CHANGED work is not adopted", %{run_id: run_id} do
      original = [task: "build the parser"]
      Journal.record_queued(run_id, 0, original)

      Journal.record_result(run_id, 0, original, %{
        node_id: "n0",
        worktree_ref: nil,
        files_changed: [],
        gate: :pass,
        stubbed: [],
        summary: "completed",
        error: nil
      })

      # The caller resumes with a DIFFERENT item at seq 0.
      assert Journal.completed(run_id, [[task: "delete the parser"]]) == %{},
             "a stale result was adopted for work that is no longer the same"
    end

    test "outstanding/1 names the items the run still owed", %{run_id: run_id} do
      items = for n <- 0..2, do: [task: "t#{n}"]

      for {item, idx} <- Enum.with_index(items), do: Journal.record_queued(run_id, idx, item)

      Journal.record_result(run_id, 1, Enum.at(items, 1), %{
        node_id: "t1",
        worktree_ref: nil,
        files_changed: [],
        gate: :pass,
        stubbed: [],
        summary: "completed",
        error: nil
      })

      assert Journal.outstanding(run_id) == [0, 2]
    end

    test "a torn final line loses only the newest entry", %{run_id: run_id} do
      item = [task: "t0"]
      Journal.record_queued(run_id, 0, item)

      Journal.record_result(run_id, 0, item, %{
        node_id: "t0",
        worktree_ref: nil,
        files_changed: [],
        gate: :pass,
        stubbed: [],
        summary: "completed",
        error: nil
      })

      File.write!(Journal.path(run_id), ~s({"seq":1,"kind":"resu), [:append])

      assert Map.has_key?(Journal.completed(run_id, [item]), 0),
             "a torn append destroyed every earlier entry"
    end

    test "a corrupted gate decodes to :fail, never to :pass", %{run_id: run_id} do
      item = [task: "t0"]

      File.mkdir_p!(Journal.dir())

      File.write!(
        Journal.path(run_id),
        Jason.encode!(%{
          "seq" => 0,
          "kind" => "result",
          "request_hash" => Journal.request_hash(item),
          "result" => %{"node_id" => "t0", "gate" => "definitely-green"}
        }) <> "\n"
      )

      assert %{0 => %{gate: :fail}} = Journal.completed(run_id, [item])
    end
  end

  describe "fan_out/3 journals as it goes" do
    test "a run that completes cleanly leaves no journal behind", %{
      run_id: run_id,
      parent: parent
    } do
      items = [[task: "a"], [task: "b"]]
      spawn_fun = fn _p, o -> {:ok, Keyword.get(o, :task)} end

      {:ok, %{run_id: returned}} =
        Fleet.fan_out(parent, items, opts(spawn_fun, run_id: run_id))

      assert returned == run_id
      refute File.exists?(Journal.path(run_id))
    end

    test "fan_out/3 mints and returns a run id when none is given", %{parent: parent} do
      spawn_fun = fn _p, o -> {:ok, Keyword.get(o, :task)} end

      {:ok, %{run_id: run_id}} = Fleet.fan_out(parent, [[task: "a"]], opts(spawn_fun))

      assert is_binary(run_id) and run_id != ""
      on_exit(fn -> Journal.discard(run_id) end)
    end

    test "an item's result is durable before the run ends", %{run_id: run_id, parent: parent} do
      # The second item stays busy while the test reads the first item's
      # journalled result, proving the record is written per item rather than
      # once at the end of the drain — which is the whole point: a coordinator
      # that dies at item 9 of 10 must keep items 1..8.
      items = [[task: "first"], [task: "second"]]

      spawn_fun = fn _p, o ->
        if Keyword.get(o, :task) == "second", do: Process.sleep(400)
        {:ok, Keyword.get(o, :task)}
      end

      task =
        Task.async(fn -> Fleet.fan_out(parent, items, opts(spawn_fun, run_id: run_id)) end)

      poll = fn poll, n ->
        cond do
          Map.has_key?(Journal.completed(run_id, items), 0) -> :ok
          n <= 0 -> :timeout
          true -> Process.sleep(20) && poll.(poll, n - 1)
        end
      end

      assert poll.(poll, 15) == :ok,
             "item 0's result was not durable until the whole run had finished"

      assert {:ok, %{results: results}} = Task.await(task, 5_000)
      assert length(results) == 2
    end
  end
end
