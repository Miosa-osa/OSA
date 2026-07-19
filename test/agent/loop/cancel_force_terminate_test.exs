defmodule OptimalSystemAgent.Agent.Loop.CancelForceTerminateTest do
  @moduledoc """
  D1 regression: `Loop.cancel/1` must not just flip a cooperative ETS flag —
  it must force-terminate a descendant SUBAGENT's live GenServer so a caller
  genuinely blocked joining it (`GenServer.call`/`Task.await`) unblocks
  immediately, instead of waiting for the child to notice the flag between
  ReactLoop iterations (which never happens if it is stuck inside ONE long
  op).

  Uses a lightweight dummy GenServer registered under `SessionRegistry` (NOT
  a real `Loop`) so this exercises `Loop.cancel/1`'s termination logic in
  isolation, independent of the full ReactLoop/TurnPipeline machinery.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.RunStore

  @cancel_table :osa_cancel_flags

  setup do
    :ets.new(@cancel_table, [:named_table, :public, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp sid(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  defmodule DummyStuckServer do
    @moduledoc "Never replies to :block — simulates a child stuck inside one long op."
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(:ok), do: {:ok, %{}}

    def handle_call(:block, _from, state) do
      # Simulate being stuck: sleep far longer than any reasonable test
      # timeout instead of replying.
      Process.sleep(60_000)
      {:reply, :ok, state}
    end
  end

  defp assert_registry_empty(id, attempts \\ 20)

  defp assert_registry_empty(id, 0),
    do: assert(Registry.lookup(OptimalSystemAgent.SessionRegistry, id) == [])

  defp assert_registry_empty(id, attempts) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, id) do
      [] -> :ok
      _ -> Process.sleep(50) && assert_registry_empty(id, attempts - 1)
    end
  end

  defp start_dummy_subagent(subagent_id) do
    via = {:via, Registry, {OptimalSystemAgent.SessionRegistry, subagent_id, "subagent"}}

    spec = %{
      id: {DummyStuckServer, subagent_id},
      start: {DummyStuckServer, :start_link, [via]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(OptimalSystemAgent.SessionSupervisor, spec)
    pid
  end

  test "cancelling the parent force-terminates a stuck descendant subagent, unblocking a caller mid-GenServer.call" do
    parent_id = sid("cparent")
    subagent_id = "agent:#{parent_id}:1"

    RunStore.start_run(%{
      agent_id: subagent_id,
      parent_session_id: parent_id,
      role: "agent",
      task: "t"
    })

    pid = start_dummy_subagent(subagent_id)
    assert Process.alive?(pid)

    test_pid = self()

    {:ok, _waiter} =
      Task.start(fn ->
        via = {:via, Registry, {OptimalSystemAgent.SessionRegistry, subagent_id, "subagent"}}

        result =
          try do
            GenServer.call(via, :block, 30_000)
          catch
            :exit, reason -> {:exit, reason}
          end

        send(test_pid, {:blocked_call_result, result})
      end)

    # Give the waiter a moment to actually be inside the blocking call.
    Process.sleep(200)
    assert Process.alive?(pid)

    Loop.cancel(parent_id)

    # Must unblock FAR sooner than the 30s GenServer.call timeout and the 60s
    # sleep inside the dummy server — proves cancel actually reached the
    # blocked child instead of the caller just riding out its own timeout.
    assert_receive {:blocked_call_result, {:exit, _reason}}, 2_000

    refute Process.alive?(pid)
    # Registry deregistration happens via the Registry's own monitor after
    # the process dies — give it a moment instead of asserting in the same
    # instant terminate_child returns (avoids a flaky race under async load).
    assert_registry_empty(subagent_id)
  end

  test "cancelling a NON-subagent (no RunStore parent) does not force-terminate it — top-level session survives Esc" do
    root_id = sid("toplevel")

    via = {:via, Registry, {OptimalSystemAgent.SessionRegistry, root_id, "user"}}

    spec = %{
      id: {DummyStuckServer, root_id},
      start: {DummyStuckServer, :start_link, [via]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(OptimalSystemAgent.SessionSupervisor, spec)
    assert Process.alive?(pid)

    Loop.cancel(root_id)

    # Cooperative flag still gets set...
    assert [{^root_id, true}] = :ets.lookup(@cancel_table, root_id)

    # ...but the live top-level session process is NOT force-killed, because
    # RunStore has no row for it (it is not a spawned subagent).
    Process.sleep(200)
    assert Process.alive?(pid)

    DynamicSupervisor.terminate_child(OptimalSystemAgent.SessionSupervisor, pid)
  end
end
