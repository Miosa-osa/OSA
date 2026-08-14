defmodule OptimalSystemAgent.Agent.Loop.VerificationAdequacyTest do
  @moduledoc """
  The completion gate must require ADEQUACY, not liveness.

  Motivation, measured (`docs/research/turn-count-diagnosis.md` §5.2): on
  `cancel-async-tasks` OSA failed in 13 turns / 106 s, wrote **zero** persisted
  test files, ran five throwaway `python3 - << 'PYEOF'` probes and declared
  "**Verified:** concurrency cap respected". mini-swe-agent solved the same task
  in 56 turns / 351 s with four named test files and four write -> test -> fix
  iterations. The old gate — "did something exit 0 and touch the changed file" —
  passed OSA's run, because a probe the model wrote in order to satisfy the gate
  satisfies the gate.

  The `replays actual head-to-head artefacts` block below is the specific
  discrimination the change exists to produce, driven by the real command
  sequences from `bench/headtohead/runs/h2h-1/`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: L
  alias OptimalSystemAgent.Agent.Loop.VerificationGate, as: G

  setup do
    sid = "adequacy-#{System.unique_integer([:positive])}"
    L.reset(sid)
    on_exit(fn -> L.reset(sid) end)
    {:ok, session_id: sid}
  end

  defp sh(sid, cmd, ok),
    do: L.record(sid, %{tool: "shell_execute", args: %{"command" => cmd}, success: ok})

  defp edit(sid, path, ok \\ true),
    do: L.record(sid, %{tool: "file_edit", args: %{"path" => path}, success: ok})

  # ===========================================================================
  # The replay
  # ===========================================================================

  describe "replays actual head-to-head artefacts" do
    test "REJECTS OSA's run: a source file written via shell, five inline probes, no test file",
         %{session_id: sid} do
      # Verbatim command prefixes from
      # arms/osa/.../cancel-async-tasks__rr8ar7S/agent/osa-events.jsonl.
      sh(sid, "python3 --version && ls /app/ 2>/dev/null", true)
      L.record(sid, %{tool: "dir_list", args: %{"path" => "/app"}, success: false})
      sh(sid, "ls -la /app/ 2>/dev/null", true)
      # The `file_write` was DENIED, so the ledger used to see no write at all…
      L.record(sid, %{tool: "file_write", args: %{"path" => "/app/run.py"}, success: false})
      # …and the deliverable was then produced through the shell instead.
      sh(sid, "cat > /app/run.py << 'PYEOF'\n# implementation\nPYEOF", true)
      sh(sid, "cat /app/run.py", true)
      sh(sid, "cd /app && python3 - << 'PYEOF'\nimport asyncio\nPYEOF", true)
      sh(sid, "cd /app && python3 - << 'PYEOF'\nfrom run import run_tasks\nPYEOF", false)
      sh(sid, "cat > /app/run.py << 'PYEOF'\n# rewritten\nPYEOF", true)
      sh(sid, "cd /app && python3 - << 'PYEOF'\n# Re-examine\nPYEOF", true)
      sh(sid, "cd /app && python3 - << 'PYEOF'\nimport asyncio, time\nPYEOF", true)
      sh(sid, "cd /app && python3 -c \"from run import run_tasks\"", true)

      # The shell heredoc is now visible as a source write — it was invisible
      # before, which is a second reason the gate never fired on this run.
      assert L.changed_source_files(sid) == ["/app/run.py"]

      # Not one persisted, re-runnable test in twelve calls.
      assert L.known_test_artifacts(sid) == []
      assert L.discriminating_evidence(sid) == nil
      assert L.needs_discriminating_test?(sid)

      # And so the gate blocks, instead of accepting "Verified:".
      assert G.needs_verification?(%{session_id: sid, verification_gate_prompts: 0})
    end

    test "ACCEPTS mini-swe-agent's run: named test file, red, source fix, green",
         %{session_id: sid} do
      # Verbatim from arms/mini-swe-agent/.../agent/trajectory.json, abridged to
      # the calls that carry the evidence (step numbers in comments).
      sh(sid, "cat <<'EOF' > /app/run.py\nimport asyncio\nEOF", true)
      # step 5
      sh(sid, "cat <<'EOF' > /tmp/test_run.py\nimport asyncio\nEOF", false)
      # step 6
      sh(sid, "cat <<'EOF' > /app/run.py\nimport asyncio\nEOF", true)
      # step 7
      sh(sid, "python3 /tmp/test_run.py", false)
      # step 8  — rc=130, RED
      sh(sid, "cat <<'EOF' > /app/run.py\nimport asyncio, signal\nEOF", true)
      # step 9  — the SOURCE fix
      sh(sid, "python3 -c \"import asyncio.runners; import inspect\"", true)
      # step 12 — reading CPython
      sh(sid, "cat <<'EOF' > /app/run.py\nimport signal, threading\nEOF", true)
      # step 15
      sh(sid, "python3 /tmp/test_run.py; echo EXIT", true)
      # step 27 — GREEN

      assert L.changed_source_files(sid) == ["/app/run.py"]
      assert "/tmp/test_run.py" in L.known_test_artifacts(sid)

      assert %{artifact: {:file, "/tmp/test_run.py"}, failed_at: f, fixed_at: x, passed_at: p} =
               L.discriminating_evidence(sid)

      assert f < x and x < p
      refute L.needs_discriminating_test?(sid)
      refute G.needs_verification?(%{session_id: sid, verification_gate_prompts: 0})
    end
  end

  # ===========================================================================
  # Adversarial: how a model trying to finish would try to satisfy this cheaply
  # ===========================================================================

  describe "cannot be satisfied by a cheap self-written probe" do
    test "an inline heredoc probe is not evidence, however many times it passes",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")

      for _ <- 1..5 do
        sh(sid, "python3 - << 'PY'\nimport app; assert app.f() == 1\nPY", true)
      end

      assert L.needs_discriminating_test?(sid)
    end

    test "`python3 -c` is not evidence either", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 -c \"import app\"", true)
      assert L.needs_discriminating_test?(sid)
    end

    test "a persisted test that only ever PASSED is not evidence", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "cat > /tmp/test_app.py << 'EOF'\nassert True\nEOF", true)
      sh(sid, "python3 /tmp/test_app.py", true)

      assert "/tmp/test_app.py" in L.known_test_artifacts(sid)

      assert L.needs_discriminating_test?(sid),
             "a green-on-first-run test proves only that it ran"
    end

    test "`assert False` -> watch it fail -> edit the assertion is NOT a fix",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "cat > /tmp/test_app.py << 'EOF'\nassert False\nEOF", true)
      sh(sid, "python3 /tmp/test_app.py", false)
      # Only the TEST changes between red and green — no source fix.
      sh(sid, "cat > /tmp/test_app.py << 'EOF'\nassert True\nEOF", true)
      sh(sid, "python3 /tmp/test_app.py", true)

      assert L.needs_discriminating_test?(sid),
             "the fix has to be in the code under test, not in the assertion"
    end

    test "the same file, now with a real source fix in between, IS evidence",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "cat > /tmp/test_app.py << 'EOF'\nimport app\nEOF", true)
      sh(sid, "python3 /tmp/test_app.py", false)
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 /tmp/test_app.py", true)

      refute L.needs_discriminating_test?(sid)
    end

    test "a test that fails only AFTER the fix does not count (wrong order)",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "cat > /tmp/test_app.py << 'EOF'\nimport app\nEOF", true)
      sh(sid, "python3 /tmp/test_app.py", true)
      sh(sid, "python3 /tmp/test_app.py", false)

      assert L.needs_discriminating_test?(sid)
    end

    test "writing a test file and never running it is not evidence",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "cat > /tmp/test_app.py << 'EOF'\nassert app.f()\nEOF", true)

      assert L.needs_discriminating_test?(sid)
    end

    test "a red-then-green run of a file the session never wrote and that does not exist is rejected",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 /tmp/test_does_not_exist_#{System.unique_integer([:positive])}.py", false)
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 /tmp/test_does_not_exist_#{System.unique_integer([:positive])}.py", true)

      assert L.needs_discriminating_test?(sid), "not persisted, not re-runnable"
    end

    test "the command that WROTE the test file cannot double as a run of it",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      # A failing heredoc write followed by a passing one would otherwise look
      # like red -> fix -> green on `test_app.py`.
      sh(sid, "cat > /tmp/test_app.py << 'EOF'\nx\nEOF", false)
      edit(sid, "/tmp/app.py")
      sh(sid, "cat > /tmp/test_app.py << 'EOF'\ny\nEOF", true)

      assert L.needs_discriminating_test?(sid)
    end
  end

  describe "a pre-existing suite counts — the model need not author the test" do
    test "red suite -> source fix -> green suite is evidence", %{session_id: sid} do
      edit(sid, "/tmp/app.ex")
      sh(sid, "mix test", false)
      edit(sid, "/tmp/app.ex")
      sh(sid, "mix test", true)

      assert %{artifact: {:suite, _}} = L.discriminating_evidence(sid)
      refute L.needs_discriminating_test?(sid)
    end

    test "a green-only suite run is not evidence", %{session_id: sid} do
      edit(sid, "/tmp/app.ex")
      sh(sid, "mix test", true)
      assert L.needs_discriminating_test?(sid)
    end

    test "a build passing is not a test — `go build` forms no suite identity",
         %{session_id: sid} do
      edit(sid, "/tmp/app.go")
      sh(sid, "go build ./...", false)
      edit(sid, "/tmp/app.go")
      sh(sid, "go build ./...", true)

      assert L.needs_discriminating_test?(sid)
    end
  end

  # ===========================================================================
  # It must not trap the agent
  # ===========================================================================

  describe "bounded escape" do
    test "a documentation-only change never triggers the requirement", %{session_id: sid} do
      edit(sid, "/tmp/README.md")
      edit(sid, "/tmp/CHANGELOG.md")
      sh(sid, "cat /tmp/README.md", true)

      refute L.needs_discriminating_test?(sid)
    end

    test "a config-only change never triggers the requirement", %{session_id: sid} do
      edit(sid, "/tmp/config.yaml")
      edit(sid, "/tmp/settings.json")

      refute L.needs_discriminating_test?(sid)
    end

    test "a docs-only change completes: gate does not fire once a check has passed",
         %{session_id: sid} do
      edit(sid, "/tmp/README.md")
      sh(sid, "markdownlint /tmp/README.md", true)

      refute G.needs_verification?(%{session_id: sid, verification_gate_prompts: 0}),
             "no runnable test is possible and none is demanded"
    end

    test "the explicit NO_RUNNABLE_TEST escape releases the gate, but only after one pushback",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      assert G.trigger(sid, 0, nil) == :inadequate_test

      # First pushback: the escape is NOT yet honoured — the model has to have
      # been asked once and tried.
      assert G.trigger(sid, 0, "NO_RUNNABLE_TEST: no python in this image") == :inadequate_test

      # Second and later: honoured.
      assert G.trigger(sid, 1, "NO_RUNNABLE_TEST: no python in this image") == nil

      refute G.needs_verification?(
               %{session_id: sid, verification_gate_prompts: 1},
               "NO_RUNNABLE_TEST: no test harness in this image"
             )
    end

    test "the escape cannot mask an outright unchecked write", %{session_id: sid} do
      edit(sid, "/tmp/app.py")

      assert G.trigger(sid, 2, "NO_RUNNABLE_TEST: nope") == :unchecked_write,
             "declaring no test possible does not excuse never running anything"
    end

    test "the re-prompt cap always releases the loop", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      assert G.needs_verification?(%{session_id: sid, verification_gate_prompts: 2})
      refute G.needs_verification?(%{session_id: sid, verification_gate_prompts: 3})
    end
  end

  # ===========================================================================
  # The directive itself
  # ===========================================================================

  describe "directive text" do
    test "never advertises re-reading a file as a way to satisfy the gate",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      {d1, st} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})
      sh(sid, "python3 -m py_compile /tmp/app.py", true)
      {d2, _} = G.build_directive(st)

      for d <- [d1, d2] do
        assert d.role == "user"
        refute d.content =~ "Re-read"
        refute d.content =~ "file_read"
      end
    end

    test "the adequacy directive states all three properties and the escape",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      {d, st} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})

      assert d.content =~ "PERSISTED"
      assert d.content =~ "RE-RUNNABLE"
      assert d.content =~ "FAILED AT LEAST ONCE"
      assert d.content =~ "NO_RUNNABLE_TEST"
      assert st.verification_gate_prompts == 1
    end

    test "ending on a red check gets its own directive, naming the command",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "pytest /tmp/test_app.py", false)

      {d, _} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})
      assert d.content =~ "RAN AND FAILED"
      assert d.content =~ "pytest /tmp/test_app.py"
    end

    test "the early nudge fires on a source change with no test yet, and stops once there is one",
         %{session_id: sid} do
      refute G.first_write_nudge(sid)

      edit(sid, "/tmp/app.py")
      nudge = G.first_write_nudge(sid)
      assert nudge =~ "PERSISTED test file"
      assert nudge =~ "app.py"

      sh(sid, "cat > /tmp/test_app.py << 'EOF'\nx\nEOF", true)
      sh(sid, "python3 /tmp/test_app.py", false)
      refute G.first_write_nudge(sid)
    end

    test "the early nudge stays quiet on a docs-only change", %{session_id: sid} do
      edit(sid, "/tmp/NOTES.md")
      refute G.first_write_nudge(sid)
    end
  end
end
