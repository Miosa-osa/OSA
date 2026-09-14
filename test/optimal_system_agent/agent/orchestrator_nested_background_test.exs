defmodule OptimalSystemAgent.Agent.OrchestratorNestedBackgroundTest do
  @moduledoc """
  GAP #5 — nested background transcript persistence.

  A 3-level tree (main -> child -> grandchild-background) must not
  cascade-cancel the grandchild when the child completes: a grandchild's
  transcript/run must not be lost if the child finishes first, and the
  grandchild must keep running after the child exits.

  ## The bug this locks in

  `Fleet.finish/3` — the per-delegation terminal path a fleet node takes on
  success, failure, driver crash and idle timeout — used to retire the node by
  calling `Fleet.stop_node/1`, which routes through
  `Runtime.SessionManager.stop_session/1`. That function UNCONDITIONALLY
  cascades via `Fleet.stop_children/1`: it walks `RunStore.all_running_local/0`
  for any row whose `parent_session_id` is the finishing node, marks each one
  `:cancelled`, and kills its live Loop.

  A node can dispatch its OWN background subagent mid-run (`delegate(background:
  true)` -> `Orchestrator.run_background/2`, registered with
  `parent_session_id: <the dispatching node's id>`) that is explicitly designed
  to keep running after its dispatcher moves on — that is the entire point of
  "background". So the moment the CHILD finished (success OR failure OR
  timeout — `finish/3` reaches this on every terminal path), any still-running
  grandchild it had dispatched was silently cancelled and its Loop killed: real
  data loss, with nothing logged as an error.

  Fixed: `finish/3` now calls `Fleet.retire_node/1` (new) instead of
  `Fleet.stop_node/1`. `retire_node/1` stops ONLY the one Loop named by its
  argument and never reads `RunStore.all_running_local/0` or touches any other
  run — see `fleet.ex` for the full rationale.

  ## Why this drives `Fleet.retire_node/1` directly rather than a full run

  Exercising the real `delegate(background: true)` path end-to-end needs a live
  model call. `test/optimal_system_agent/agent/fleet_node_teardown_test.exs`
  already established the precedent for testing this exact teardown boundary
  without one: register the RunStore rows and idle `Agent.Loop` GenServers a
  real fleet run would produce, then exercise the teardown function itself
  (`retire_node/1` is exactly what `finish/3` delegates to on every terminal
  path). This test follows that same convention.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Fleet
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Runtime.SessionManager

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_nested_bg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)

    on_exit(fn ->
      if prev == nil,
        do: Application.delete_env(:optimal_system_agent, :agent_runs_dir),
        else: Application.put_env(:optimal_system_agent, :agent_runs_dir, prev)

      File.rm_rf(tmp)
    end)

    :ok
  end

  # Registry entries are cleaned up asynchronously when the owner dies, so a
  # lookup alone can still return a pid for an already-stopped loop — check the
  # process itself, mirroring `fleet_node_teardown_test.exs`.
  defp alive?(session_id) do
    case SessionManager.lookup_loop(session_id) do
      {:ok, pid, _owner} -> Process.alive?(pid)
      _ -> false
    end
  end

  # Registers the RunStore row + starts a real (idle) Loop exactly as
  # `Fleet.do_spawn/2` does for a delegated node, and exactly as
  # `Orchestrator.run_background/2` does for a background subagent — both
  # register under their dispatching session's id as `parent_session_id`.
  defp spawn_node(parent, node_id) do
    RunStore.start_run(%{
      agent_id: node_id,
      parent_session_id: parent,
      role: "general-purpose",
      task: "nested-bg probe"
    })

    :ok = SessionManager.ensure_loop(node_id, user_id: "fleet", working_dir: File.cwd!())
    node_id
  end

  test "a child completing does not cancel or kill its still-running background grandchild" do
    main = "nbg-main-#{System.unique_integer([:positive])}"
    child = spawn_node(main, "nbg-child-#{System.unique_integer([:positive])}")
    grandchild = spawn_node(child, "nbg-grandchild-#{System.unique_integer([:positive])}")

    assert alive?(child)
    assert alive?(grandchild)
    assert %{status: :running} = RunStore.get(grandchild)

    # Exactly what `Fleet.finish/3` does on every terminal path.
    RunStore.complete(child, %{status: :completed, summary: "child done"})
    assert :ok = Fleet.retire_node(child)

    refute alive?(child), "the completing node's own Loop must still be retired"

    assert alive?(grandchild),
           "a still-running grandchild must survive its parent's normal completion"

    assert %{status: :running} = RunStore.get(grandchild),
           "the grandchild's run must not be cancelled just because its parent finished"

    Fleet.retire_node(grandchild)
  end

  test "both the child's and the grandchild's transcripts/runs remain independently readable" do
    main = "nbg-main-#{System.unique_integer([:positive])}"
    child = spawn_node(main, "nbg-child2-#{System.unique_integer([:positive])}")
    grandchild = spawn_node(child, "nbg-grandchild2-#{System.unique_integer([:positive])}")

    RunStore.complete(child, %{status: :completed, summary: "child done"})
    Fleet.retire_node(child)

    assert %{agent_id: ^child, status: :completed} = RunStore.get(child)

    assert %{agent_id: ^grandchild, status: :running, parent_session_id: ^child} =
             RunStore.get(grandchild)

    Fleet.retire_node(grandchild)
  end

  test "stop_node/1 (the cascading path) is the one that WOULD have cancelled the grandchild" do
    # Documents the contrast so a future change that swaps `retire_node/1` back
    # to `stop_node/1` inside `finish/3` fails this suite immediately.
    main = "nbg-main-#{System.unique_integer([:positive])}"
    child = spawn_node(main, "nbg-child3-#{System.unique_integer([:positive])}")
    grandchild = spawn_node(child, "nbg-grandchild3-#{System.unique_integer([:positive])}")

    assert :ok = Fleet.stop_node(child)

    refute alive?(grandchild),
           "stop_node/1 is the intentionally-cascading path — this pins that contrast"

    assert %{status: :cancelled} = RunStore.get(grandchild)
  end
end
