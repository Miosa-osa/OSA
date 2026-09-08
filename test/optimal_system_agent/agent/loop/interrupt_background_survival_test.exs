defmodule OptimalSystemAgent.Agent.Loop.InterruptBackgroundSurvivalTest do
  @moduledoc """
  User-decided interrupt semantics: "stop the turn, background agents keep
  running."

  `SessionManager.cancel/1` (Ctrl+C / Esc-Esc → `POST /sessions/:id/cancel`,
  the TUI's interrupt) stops the parent session's current turn and its
  attached/foreground/synchronous work — a fan-out workstream the parent
  awaits, a plain foreground `delegate`. It must NOT reach a run dispatched
  via `Orchestrator.run_background/2` (`delegate(background: true)` and
  anything reusing that entry point) — that work is explicitly designed to
  outlive the turn that spawned it.

  `SessionManager.stop_session/1` (real teardown — session switch/delete,
  scheduler shutdown) is the opposite: it MUST still cascade into a background
  run, or a genuine shutdown leaks it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Cancellation
  alias OptimalSystemAgent.Agent.Fleet
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Runtime.SessionManager

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_interrupt_bg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)

    on_exit(fn ->
      if prev == nil,
        do: Application.delete_env(:optimal_system_agent, :agent_runs_dir),
        else: Application.put_env(:optimal_system_agent, :agent_runs_dir, prev)

      File.rm_rf(tmp)
    end)

    {:ok, parent: "interrupt-bg-parent-#{System.unique_integer([:positive])}"}
  end

  defp spawn_child(parent, id, background?) do
    RunStore.start_run(%{
      agent_id: id,
      parent_session_id: parent,
      role: if(background?, do: "background", else: "agent"),
      task: "probe",
      background: background?
    })

    :ok = SessionManager.ensure_loop(id, user_id: "interrupt-bg-test", working_dir: File.cwd!())

    # Several cases here deliberately assert the Loop is STILL alive at the
    # end of the test (that is the whole point of the interrupt exclusion) —
    # clean it up regardless of the assertions above, or it leaks a live
    # GenServer plus a `:running` RunStore row into every OTHER test sharing
    # this VM (`Fleet.stop_node/1` is idempotent and a no-op on an already-
    # stopped node, so this is safe whether or not the test itself stopped it).
    on_exit(fn -> Fleet.stop_node(id) end)

    id
  end

  defp alive?(session_id) do
    case SessionManager.lookup_loop(session_id) do
      {:ok, pid, _owner} -> Process.alive?(pid)
      _ -> false
    end
  end

  describe "(a) interrupt with a background agent running" do
    test "the background agent survives — Loop alive, RunStore :running, not flagged",
         %{parent: parent} do
      bg = spawn_child(parent, "agent:#{parent}:bg", true)

      assert :ok = SessionManager.cancel(parent)

      assert alive?(bg), "an interrupt of the parent turn must not stop a background child's Loop"
      refute Cancellation.cancelled?(bg), "a background child must not receive the cancel flag"
      assert %{status: :running} = RunStore.get(bg)
    end
  end

  describe "(b) real session teardown with a background agent" do
    test "the background agent IS stopped — no leak on a genuine shutdown",
         %{parent: parent} do
      bg = spawn_child(parent, "agent:#{parent}:bg", true)

      assert alive?(bg)

      SessionManager.stop_session(parent)

      refute alive?(bg),
             "a real session teardown must still cascade into a background child — " <>
               "the interrupt exclusion applies ONLY to Loop.cancel/1, never to stop_session/1"
    end
  end

  describe "(c) attached/foreground child of the interrupted turn" do
    test "stops with the turn — unchanged from before this fix", %{parent: parent} do
      fg = spawn_child(parent, "agent:#{parent}:fg", false)

      assert :ok = SessionManager.cancel(parent)

      refute alive?(fg),
             "an attached/foreground child must still be force-terminated by an interrupt"
    end
  end

  describe "mixed subtree" do
    test "one interrupt: the attached sibling stops, the background sibling survives",
         %{parent: parent} do
      bg = spawn_child(parent, "agent:#{parent}:bg", true)
      fg = spawn_child(parent, "agent:#{parent}:fg", false)

      assert :ok = SessionManager.cancel(parent)

      assert alive?(bg)
      refute alive?(fg)
    end
  end
end
