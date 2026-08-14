defmodule OptimalSystemAgent.Agent.Loop.VerificationEngagementTest do
  @moduledoc """
  Clause 0: the completion gate must refuse a claim that rests on work the
  model has not observed.

  Motivation, measured on `bench/terminalbench/runs/osa-tb20-full89-f6981b61`
  (replay it with `scripts/engagement_replay.py`): a cluster of failures ended
  `status=ok`, carried no self-inflicted markers, and passed all three existing
  clauses. Every one of them finished its last turn while a background command
  it had started was still running, deferring verification to a notification
  that never arrives, because the episode ends when the model stops:

      hf-model-inference  "I'll run the full test suite the moment the download completes."
      sqlite-with-gcov    "I'll wait for the completion notification rather than re-checking."
      query-optimize      "Waiting for the background test to complete on its own."

  The hypothesis this replaced was "turns that did not think", proxied by wall
  clock. The proxy fires on 13 of 37 solves in the same arm and is not used
  here; the tests below pin the FALSE-POSITIVE half of the contract as hard as
  the detection half, because a gate that stops fast correct work is worse than
  no gate.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: L
  alias OptimalSystemAgent.Agent.Loop.VerificationGate, as: G

  # Stub standing in for `Shell.BackgroundManager`, injected through the same
  # `:background_manager` config key production reads. Returns whatever the
  # test parked in the process-independent application env, in the exact shape
  # `BackgroundTask.snapshot/1` produces.
  defmodule StubBackground do
    def list, do: Application.get_env(:optimal_system_agent, :test_background_snapshots, [])
  end

  defmodule RaisingBackground do
    def list, do: raise("registry is down")
  end

  setup do
    sid = "engagement-#{System.unique_integer([:positive])}"
    L.reset(sid)
    Application.put_env(:optimal_system_agent, :background_manager, StubBackground)
    Application.put_env(:optimal_system_agent, :test_background_snapshots, [])

    on_exit(fn ->
      L.reset(sid)
      Application.delete_env(:optimal_system_agent, :background_manager)
      Application.delete_env(:optimal_system_agent, :test_background_snapshots)
      Application.delete_env(:optimal_system_agent, :verification_engagement)
      System.delete_env("OSA_VERIFICATION_ENGAGEMENT")
    end)

    {:ok, session_id: sid}
  end

  defp running(sid, id, cmd),
    do: %{id: id, command: cmd, session_id: sid, status: :running, exit_code: nil}

  defp finished(sid, id, cmd),
    do: %{id: id, command: cmd, session_id: sid, status: :done, exit_code: 0}

  defp bg(snapshots),
    do: Application.put_env(:optimal_system_agent, :test_background_snapshots, snapshots)

  # A fully verified session: a persisted test that went red then green across a
  # source fix. Everything below is therefore attributable to clause 0 alone —
  # clauses 1-3 have nothing to say about these sessions.
  defp fully_verified(sid) do
    L.record(sid, %{tool: "file_write", args: %{"path" => "/app/svc.py"}, success: true})

    L.record(sid, %{
      tool: "file_write",
      args: %{"path" => "/app/tests/test_svc.py"},
      success: true
    })

    L.record(sid, %{
      tool: "shell_execute",
      args: %{"command" => "python3 /app/tests/test_svc.py"},
      success: false
    })

    L.record(sid, %{tool: "file_edit", args: %{"path" => "/app/svc.py"}, success: true})

    L.record(sid, %{
      tool: "shell_execute",
      args: %{"command" => "python3 /app/tests/test_svc.py"},
      success: true
    })
  end

  describe "detection" do
    test "fires when a job this session started is still running", %{session_id: sid} do
      fully_verified(sid)
      refute G.needs_verification?(%{session_id: sid, verification_gate_prompts: 0}, "Done.")

      bg([running(sid, "bg_1", "cd /app && python3 train.py 2>&1")])

      assert G.trigger(sid, 0, "Training is still going. I'll re-run the test once it finishes.") ==
               :unobserved_background

      assert G.needs_verification?(%{session_id: sid, verification_gate_prompts: 0}, "Done.")
    end

    test "is silent once the job has finished", %{session_id: sid} do
      fully_verified(sid)
      bg([finished(sid, "bg_1", "cd /app && python3 train.py 2>&1")])
      assert G.trigger(sid, 0, "Done.") == nil
    end

    test "ignores jobs belonging to another session", %{session_id: sid} do
      fully_verified(sid)
      bg([running("some-other-session", "bg_9", "sleep 600")])
      assert G.trigger(sid, 0, "Done.") == nil
      assert G.unobserved_background(sid) == []
    end

    test "outranks the ledger clauses — a red check under a running job reports the job",
         %{session_id: sid} do
      # A failing check since the last write would normally be :failing_check.
      L.record(sid, %{tool: "file_write", args: %{"path" => "/app/svc.py"}, success: true})
      L.record(sid, %{tool: "shell_execute", args: %{"command" => "pytest"}, success: false})
      assert G.trigger(sid, 0, "Done.") == :failing_check

      bg([running(sid, "bg_1", "pytest -x")])
      assert G.trigger(sid, 0, "Done.") == :unobserved_background
    end
  end

  describe "false positives — the half that matters more" do
    test "stays silent with no background work at all, however fast the session was",
         %{session_id: sid} do
      # `fix-code-vulnerability` shape: solved at 2.2 s/turn with 19 reasoning
      # characters per turn, the least-engaged episode in the arm and correct.
      # Nothing about speed or reasoning volume may reach this clause.
      fully_verified(sid)
      bg([])
      assert G.trigger(sid, 0, "Fixed and the suite is green.") == nil
    end

    test "the explicit escape releases it immediately, without a wasted round trip",
         %{session_id: sid} do
      fully_verified(sid)
      bg([running(sid, "bg_1", "python /app/server.py")])

      assert G.trigger(sid, 0, "Tests pass.") == :unobserved_background

      answer = """
      All four tests pass against the running server.
      BACKGROUND_INTENTIONAL: the gRPC server under test must stay up.
      """

      assert G.trigger(sid, 0, answer) == nil
    end

    test "one pushback per turn, shared with the adequacy clause — never two",
         %{session_id: sid} do
      # The adequacy gate is measured at ~31% of tokens on the tasks where it
      # fires. Clause 0 must not be a second charge on top of it: it consumes
      # the SAME per-turn counter, so a turn that has already been pushed back
      # once is not pushed back again.
      L.record(sid, %{tool: "file_write", args: %{"path" => "/app/svc.py"}, success: true})

      L.record(sid, %{
        tool: "shell_execute",
        args: %{"command" => "python3 -m py_compile /app/svc.py"},
        success: true
      })

      bg([running(sid, "bg_1", "pytest")])

      assert G.needs_verification?(%{session_id: sid, verification_gate_prompts: 0}, "Done.")
      refute G.needs_verification?(%{session_id: sid, verification_gate_prompts: 1}, "Done.")
    end
  end

  describe "kill switch and failure modes" do
    test "OSA_VERIFICATION_ENGAGEMENT=0 turns it off, leaving clauses 1-3 intact",
         %{session_id: sid} do
      L.record(sid, %{tool: "file_write", args: %{"path" => "/app/svc.py"}, success: true})
      L.record(sid, %{tool: "shell_execute", args: %{"command" => "pytest"}, success: false})
      bg([running(sid, "bg_1", "pytest -x")])
      assert G.trigger(sid, 0, "Done.") == :unobserved_background

      System.put_env("OSA_VERIFICATION_ENGAGEMENT", "0")
      assert G.unobserved_background(sid) == []
      # Clause 1 still answers, so the switch is scoped to clause 0 alone.
      assert G.trigger(sid, 0, "Done.") == :failing_check
    end

    test "the config key turns it off too", %{session_id: sid} do
      fully_verified(sid)
      bg([running(sid, "bg_1", "pytest")])
      assert G.trigger(sid, 0, "Done.") == :unobserved_background

      Application.put_env(:optimal_system_agent, :verification_engagement, false)
      assert G.trigger(sid, 0, "Done.") == nil
    end

    test "a broken background manager reads as silence, never as a fire",
         %{session_id: sid} do
      fully_verified(sid)
      Application.put_env(:optimal_system_agent, :background_manager, RaisingBackground)
      assert G.unobserved_background(sid) == []
      assert G.trigger(sid, 0, "Done.") == nil
    end

    test "a nil session id is silent", _ do
      assert G.unobserved_background(nil) == []
    end
  end

  describe "the directive" do
    test "names the command, offers wait/kill/declare, and forbids the promise",
         %{session_id: sid} do
      fully_verified(sid)
      bg([running(sid, "bg_gMnfY2Km", "cd /app && python3 train.py 2>&1")])

      {directive, state} =
        G.build_directive(%{session_id: sid, verification_gate_prompts: 0}, "I'll check later.")

      # `user`, not `system`: this is appended after assistant text, where
      # Anthropic and Gemini reject a system message with a 400.
      assert directive.role == "user"
      assert state.verification_gate_prompts == 1

      body = directive.content
      assert body =~ "bg_gMnfY2Km"
      assert body =~ "python3 train.py"
      assert body =~ "bash_output"
      assert body =~ "BACKGROUND_INTENTIONAL"
      assert body =~ "do not promise to check"

      # It must not scold the model for stopping early. The episodes this
      # catches include one that ran 62 turns; length is not the defect and a
      # length-shaped instruction would be wrong on half the cluster.
      refute body =~ ~r/too (soon|early)/i
      refute body =~ ~r/keep going|more turns/i
    end
  end
end
