defmodule OptimalSystemAgent.Agent.Loop.DelegatedChildIsOutstandingWorkTest do
  @moduledoc """
  A delegated subagent that is still running is outstanding work, and the
  completion gate must see it.

  ## The reproduction

  Observed on a live v1.0.099 session (`glm-5.2:cloud`, overdrive, 76% context).
  The model delegated, said so, kept working, and then ended its turn on:

      Let me wait for the explorer to finish the backend session model map,
      then I'll do both. Should be any moment now.

      Plan  0/5
      ✻ Worked for 26s · 10 tool uses

  Five plan items open, zero done, and the child still running. This is the
  same species as the `hf-model-inference` / `sqlite-with-gcov` / `query-optimize`
  cluster that `VerificationEngagementTest` pins — a completion claim resting on
  work the model has not observed — and clause 0 of the gate exists to refuse
  exactly that.

  It did not fire, and could not have. `VerificationGate.unobserved_background/1`
  asks `Shell.BackgroundManager.list/0`, and the ONLY writers into that manager
  are `shell_execute`'s `start/3` and `adopt/1`
  (lib/optimal_system_agent/tools/builtins/shell_execute/handler.ex:248,652,715).
  `delegate` never registers there — a background subagent lives in
  `Agent.RunStore` — so clause 0 is structurally blind to the one kind of
  background work OSA spawns most.

  The consequence is not just an early finish. The turn ends, the loop goes
  idle, and the child's result comes back through
  `BackgroundNotifier` → `TaskNotifications.queue/2` → `Loop.poke/1`. That path
  only runs a synthetic turn from `handle_cast(:poke, %{status: :idle})`
  (agent/loop.ex:1812); a poke that lands on a loop which is not yet idle is
  dropped by the catch-all clause at agent/loop.ex:1836, and nothing re-pokes.
  Nothing anywhere calls `TaskNotifications.pending?/1` — it has no production
  caller at all — so no turn boundary ever asks whether a result is sitting
  unread. Holding the turn open while the child is alive closes both halves.

  These tests pin the FALSE-POSITIVE half as hard as the detection half, for the
  reason `VerificationEngagementTest` gives: a gate that stops fast correct work
  is worse than no gate.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: L
  alias OptimalSystemAgent.Agent.Loop.VerificationGate, as: G

  # No shell background work anywhere in this file — every fire below is
  # attributable to the subagent roster alone.
  defmodule NoShellJobs do
    def list, do: []
  end

  # Stands in for `Agent.RunStore`, injected through the same config-key
  # convention `:background_manager` already uses, and returning rows in the
  # exact shape `RunStore.all_running_local/0` produces.
  defmodule StubRoster do
    def all_running_local,
      do: Application.get_env(:optimal_system_agent, :test_subagent_runs, [])
  end

  defmodule RaisingRoster do
    def all_running_local, do: raise("run store is down")
  end

  setup do
    sid = "delegated-#{System.unique_integer([:positive])}"
    L.reset(sid)
    Application.put_env(:optimal_system_agent, :background_manager, NoShellJobs)
    Application.put_env(:optimal_system_agent, :subagent_roster, StubRoster)
    Application.put_env(:optimal_system_agent, :test_subagent_runs, [])

    on_exit(fn ->
      L.reset(sid)
      Application.delete_env(:optimal_system_agent, :background_manager)
      Application.delete_env(:optimal_system_agent, :subagent_roster)
      Application.delete_env(:optimal_system_agent, :test_subagent_runs)
      Application.delete_env(:optimal_system_agent, :verification_engagement)
      System.delete_env("OSA_VERIFICATION_ENGAGEMENT")
    end)

    {:ok, session_id: sid}
  end

  defp child(parent, agent_id, role, task, status \\ :running) do
    %{
      agent_id: agent_id,
      parent_session_id: parent,
      role: role,
      task: task,
      status: status,
      tool_count: 0,
      phase: :working
    }
  end

  defp roster(runs),
    do: Application.put_env(:optimal_system_agent, :test_subagent_runs, runs)

  # A fully verified session, so clauses 1-3 have nothing to say and every
  # assertion below is clause 0 alone.
  defp fully_verified(sid) do
    L.record(sid, %{tool: "file_write", args: %{"path" => "/app/svc.ex"}, success: true})

    L.record(sid, %{
      tool: "file_write",
      args: %{"path" => "/app/test/svc_test.exs"},
      success: true
    })

    L.record(sid, %{tool: "shell_execute", args: %{"command" => "mix test"}, success: false})
    L.record(sid, %{tool: "file_edit", args: %{"path" => "/app/svc.ex"}, success: true})
    L.record(sid, %{tool: "shell_execute", args: %{"command" => "mix test"}, success: true})
  end

  describe "detection" do
    test "the live reproduction: finishing while a delegated explorer is still running",
         %{session_id: sid} do
      fully_verified(sid)
      refute G.needs_verification?(%{session_id: sid, verification_gate_prompts: 0}, "Done.")

      roster([child(sid, "ag_expl01", "explore", "map the backend session model")])

      answer = """
      Let me wait for the explorer to finish the backend session model map, then I'll do both.
      Should be any moment now.
      """

      assert G.trigger(sid, 0, answer) == :unobserved_background

      assert G.needs_verification?(
               %{session_id: sid, verification_gate_prompts: 0, background_gate_prompts: 0},
               answer
             )
    end

    test "a finished subagent is not outstanding work", %{session_id: sid} do
      fully_verified(sid)
      roster([child(sid, "ag_expl01", "explore", "map the session model", :completed)])
      assert G.trigger(sid, 0, "Done.") == nil
    end

    test "another session's subagent is not this session's obligation", %{session_id: sid} do
      fully_verified(sid)
      roster([child("some-other-session", "ag_other", "explore", "unrelated")])
      assert G.trigger(sid, 0, "Done.") == nil
      assert G.unobserved_background(sid) == []
    end

    test "a running shell command and a running subagent are both reported",
         %{session_id: sid} do
      fully_verified(sid)

      Application.put_env(:optimal_system_agent, :background_manager, __MODULE__.BothShell)

      Application.put_env(:optimal_system_agent, :test_shell_snapshots, [
        %{id: "bg_1", command: "mix test", session_id: sid, status: :running}
      ])

      roster([child(sid, "ag_expl01", "explore", "map the session model")])

      outstanding = G.unobserved_background(sid)
      assert length(outstanding) == 2
      assert "bg_1" in Enum.map(outstanding, & &1[:id])
      assert "ag_expl01" in Enum.map(outstanding, & &1[:id])

      # And the directive offers BOTH exits, each naming its own affordance.
      {directive, _} =
        G.build_directive(
          %{session_id: sid, verification_gate_prompts: 0, background_gate_prompts: 0},
          "Done."
        )

      assert directive.content =~ "task_wait"
      assert directive.content =~ "wait_ms"

      Application.delete_env(:optimal_system_agent, :test_shell_snapshots)
    end

    defmodule BothShell do
      def list, do: Application.get_env(:optimal_system_agent, :test_shell_snapshots, [])
    end
  end

  describe "the directive names an affordance that exists" do
    test "it points at task_wait, never at the tool delegate forbids", %{session_id: sid} do
      fully_verified(sid)
      roster([child(sid, "ag_expl01", "explore", "map the backend session model")])

      {directive, state} =
        G.build_directive(
          %{session_id: sid, verification_gate_prompts: 0, background_gate_prompts: 0},
          "Should be any moment now."
        )

      body = directive.content

      # It must name the agent it is talking about, and the blocking join that
      # actually exists for agents.
      assert body =~ "ag_expl01"
      assert body =~ "task_wait"

      # `delegate`'s own prompt says "do NOT poll task_output ... do not read the
      # output file before that notification arrives". A gate that answers by
      # ordering the model to do the thing the tool forbids is the contradiction
      # this codebase has already shipped once (see the `bash_output` note in
      # `VerificationGate`'s moduledoc). Do not ship it again: `task_output` may
      # appear ONLY as a prohibition, never as the instruction.
      assert body =~ ~r/Do NOT poll `task_output`/
      refute body =~ ~r/(use|call|try|run) `task_output`/i

      # No shell command is outstanding here, so the command exit must not be
      # offered at all — an exit that does not apply is noise the model can take.
      refute body =~ "bash_output"

      # Clause 0 spends its own counter, unchanged.
      assert state.background_gate_prompts == 1
      assert Map.get(state, :verification_gate_prompts) == 0

      # The defect is the unobserved claim, not the length of the run.
      refute body =~ ~r/too (soon|early)/i
      refute body =~ ~r/keep going|more turns/i
    end
  end

  describe "false positives — the half that matters more" do
    test "silent when no child is running, however fast the turn was", %{session_id: sid} do
      fully_verified(sid)
      roster([])
      assert G.trigger(sid, 0, "Fixed, and the suite is green.") == nil
    end

    test "the explicit escape releases it immediately", %{session_id: sid} do
      fully_verified(sid)
      roster([child(sid, "ag_watch", "explore", "long-lived watcher")])
      assert G.trigger(sid, 0, "Done.") == :unobserved_background

      answer = """
      Reported everything I verified myself.
      BACKGROUND_INTENTIONAL: the watcher agent is meant to outlive this turn.
      """

      assert G.trigger(sid, 0, answer) == nil
    end

    test "bounded on its own counter, then steps aside", %{session_id: sid} do
      fully_verified(sid)
      roster([child(sid, "ag_expl01", "explore", "map the session model")])

      for used <- 0..2 do
        assert G.needs_verification?(
                 %{session_id: sid, verification_gate_prompts: 0, background_gate_prompts: used},
                 "Done."
               ),
               "clause 0 should still push back after #{used} of its own pushbacks"
      end

      refute G.needs_verification?(
               %{session_id: sid, verification_gate_prompts: 0, background_gate_prompts: 3},
               "Done."
             )
    end
  end

  describe "failure modes read as silence, never as a fire" do
    test "a broken run store is silent", %{session_id: sid} do
      fully_verified(sid)
      Application.put_env(:optimal_system_agent, :subagent_roster, RaisingRoster)
      assert G.unobserved_background(sid) == []
      assert G.trigger(sid, 0, "Done.") == nil
    end

    test "the kill switch covers the subagent half too", %{session_id: sid} do
      fully_verified(sid)
      roster([child(sid, "ag_expl01", "explore", "map the session model")])
      assert G.trigger(sid, 0, "Done.") == :unobserved_background

      System.put_env("OSA_VERIFICATION_ENGAGEMENT", "0")
      assert G.unobserved_background(sid) == []
      assert G.trigger(sid, 0, "Done.") == nil
    end
  end
end
