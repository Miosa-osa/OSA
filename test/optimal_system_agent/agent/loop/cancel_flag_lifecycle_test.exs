defmodule OptimalSystemAgent.Agent.Loop.CancelFlagLifecycleTest do
  @moduledoc """
  D7 — cancel flags leaked.

  `Loop.cancel/1` inserts `{id, true}` for a WHOLE subtree (RunStore BFS, the
  cancel table's own `agent:<id>:` prefix, and the live SessionRegistry). Only
  three sites ever deleted, and each deleted exactly ONE key — the session that
  was executing a turn. A descendant that was flagged but never ran a turn
  (finished, force-terminated by `cancel/1` itself, or never started) kept its
  flag forever: `:osa_cancel_flags` grew for the life of the VM, and the readers
  in `Loop.PermissionBroker` / `Loop.Survey` treat a live flag as "cancelled" —
  so a later run under a reused agent id had its permission prompts and
  `ask_user` surveys auto-denied before it cleared anything.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.RunStore

  @cancel_table :osa_cancel_flags

  setup do
    if :ets.whereis(@cancel_table) == :undefined do
      :ets.new(@cancel_table, [:named_table, :public, read_concurrency: true])
    end

    # Loop.start_link/1 links to us; its shutdown exit must not fail the test.
    Process.flag(:trap_exit, true)
    :ok
  end

  # Stop a Loop and wait for it to be gone, tolerating the `:shutdown` exit
  # reason the loop terminates with. We only care that `terminate/2` ran.
  defp stop_and_await(pid, reason) do
    ref = Process.monitor(pid)

    try do
      GenServer.stop(pid, reason)
    catch
      :exit, _ -> :ok
    end

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> flunk("loop did not stop")
    end
  end

  defp sid(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  defp flagged?(id), do: match?([{_, true}], :ets.lookup(@cancel_table, id))

  describe "clear_cancel/1 — the inverse of cancel/1" do
    test "clears the flag for a subtree that never ran a turn" do
      root = sid("clearroot")
      child = "agent:#{root}:1"
      grandchild = "agent:#{child}:1"

      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "agent", task: "t"})

      RunStore.start_run(%{
        agent_id: grandchild,
        parent_session_id: child,
        role: "agent",
        task: "t"
      })

      Loop.cancel(root)

      # Precondition: cancel really did flag the whole subtree.
      assert flagged?(root)
      assert flagged?(child)
      assert flagged?(grandchild)

      Loop.clear_cancel(root)

      refute flagged?(root), "root flag leaked"
      refute flagged?(child), "child flag leaked — nothing will ever clear it"
      refute flagged?(grandchild), "grandchild flag leaked — nothing will ever clear it"
    end

    test "clears a prefix-flagged child that has no RunStore row at all" do
      root = sid("prefixroot")
      racing_child = "agent:#{root}:99"

      # A child that was flagged by cancel/1's prefix fold / registry scan before
      # it ever reached RunStore.start_run/1 — invisible to the BFS.
      :ets.insert(@cancel_table, {racing_child, true})
      Loop.cancel(root)
      assert flagged?(racing_child)

      Loop.clear_cancel(root)

      refute flagged?(racing_child)
    end

    test "leaves an unrelated session's flag alone" do
      root = sid("scoped")
      unrelated = sid("unrelated")

      :ets.insert(@cancel_table, {unrelated, true})
      Loop.cancel(root)
      Loop.clear_cancel(root)

      assert flagged?(unrelated)
    end
  end

  describe "a Loop's own flag is per-RUN, not per-id" do
    test "a starting Loop clears a stale flag left by a previous run of the same id" do
      id = sid("reused")

      # The previous run under this id was cancelled and force-terminated, so it
      # never reached its own delete. PermissionBroker/Survey would read this as
      # "cancelled" for the FRESH run and auto-deny its first prompt.
      :ets.insert(@cancel_table, {id, true})

      {:ok, pid} =
        Loop.start_link(session_id: id, user_id: "test", channel: :internal, messages: [])

      refute flagged?(id),
             "a freshly started Loop inherited the previous run's cancel flag"

      stop_and_await(pid, :normal)
    end

    test "a terminating Loop takes its flag with it" do
      id = sid("terminating")

      {:ok, pid} =
        Loop.start_link(session_id: id, user_id: "test", channel: :internal, messages: [])

      :ets.insert(@cancel_table, {id, true})
      assert flagged?(id)

      stop_and_await(pid, :normal)

      refute flagged?(id), "the flag outlived the process that was its only reader"
    end

    test "a Loop killed abnormally also drops its flag" do
      id = sid("abnormal")

      {:ok, pid} =
        Loop.start_link(session_id: id, user_id: "test", channel: :internal, messages: [])

      :ets.insert(@cancel_table, {id, true})

      stop_and_await(pid, :shutdown)

      refute flagged?(id)
    end
  end
end
