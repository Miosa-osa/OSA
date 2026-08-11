defmodule OptimalSystemAgent.Speculative.ExecutorTest do
  @moduledoc """
  A speculation that is still running is live state, not history.

  The row cap must never be satisfied by dropping an in-flight speculation: the
  row is the only handle on a staged temp directory, so evicting it makes
  `promote/1` answer `:not_found` and strands the artifacts on disk. And a
  `discard/1` for a row that is already gone must still clean that directory
  instead of reporting success it did not perform.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Infra.BoundedTable
  alias OptimalSystemAgent.Speculative.Executor
  alias OptimalSystemAgent.Speculative.WorkProduct

  @table :osa_speculative_executions
  @max_rows 500

  @moduletag :tmp_dir

  setup do
    case Process.whereis(Executor) do
      nil -> start_supervised!(Executor)
      _ -> :ok
    end

    :ok
  end

  # Cheap filler rows: finished speculations, written straight to the table so
  # the cap can be reached without staging 500 real work products.
  defp fill_terminal(count) do
    base = DateTime.add(DateTime.utc_now(), -86_400, :second)

    ids =
      for n <- 1..count do
        id = "filler_#{System.unique_integer([:positive])}"
        at = DateTime.add(base, n, :second)

        :ets.insert(
          @table,
          {id,
           %{
             id: id,
             agent_id: "filler-agent",
             predicted_task: %{},
             assumptions: [],
             work_product: nil,
             status: :discarded,
             started_at: at,
             resolved_at: at
           }}
        )

        id
      end

    on_exit(fn -> Enum.each(ids, &BoundedTable.delete(@table, &1)) end)
    ids
  end

  test "a running speculation is not evicted to satisfy the row cap" do
    {:ok, live_id} = Executor.start_speculative("agent-live", %{"task" => "keep me"}, ["a"])
    on_exit(fn -> Executor.discard(live_id) end)

    # Push the table past its cap, then write once more so eviction runs.
    fill_terminal(@max_rows + 5)
    {:ok, other_id} = Executor.start_speculative("agent-other", %{}, [])
    on_exit(fn -> Executor.discard(other_id) end)

    assert {:ok, %{status: :running}} = Executor.get(live_id),
           "an in-flight speculation was evicted — promote/1 can no longer find its work"

    assert {:ok, %{status: :running}} = Executor.get(other_id)
  end

  test "eviction still trims finished rows once the cap is exceeded" do
    fill_terminal(@max_rows + 20)
    {:ok, id} = Executor.start_speculative("agent-trim", %{}, [])
    on_exit(fn -> Executor.discard(id) end)

    assert BoundedTable.size(@table) <= @max_rows
  end

  test "discarding an evicted speculation still cleans its staged artifacts", %{tmp_dir: tmp} do
    {:ok, id} = Executor.start_speculative("agent-evicted", %{}, [])

    :ok =
      Executor.update_work_product(id, fn wp ->
        WorkProduct.add_file_create(wp, Path.join(tmp, "staged.txt"), "speculative content")
      end)

    {:ok, %{work_product: wp}} = Executor.get(id)
    assert File.dir?(wp.temp_dir)
    on_exit(fn -> File.rm_rf(wp.temp_dir) end)

    # Simulate the row being gone (evicted, or a caller that lost the race).
    :ets.delete(@table, id)

    assert :ok = Executor.discard(id)

    refute File.dir?(wp.temp_dir),
           "discard/1 reported success while the staged directory was still on disk"

    refute File.exists?(Path.join(tmp, "staged.txt")),
           "discarding must never touch the real target path"
  end
end
