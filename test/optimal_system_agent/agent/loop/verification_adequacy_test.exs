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

  # A change that is NOT one small site: a whole file authored at once. Every
  # tier-sensitive assertion below is stated twice, once per tier, so the
  # proportionality is pinned in both directions.
  defp authored(sid, path, ok \\ true),
    do:
      L.record(sid, %{
        tool: "file_write",
        args: %{"path" => path, "content" => String.duplicate("x\n", 60)},
        success: ok
      })

  defp large_directive do
    sid = "adequacy-large-#{System.unique_integer([:positive])}"
    L.reset(sid)
    authored(sid, "/tmp/app.py")
    sh(sid, "python3 -m py_compile /tmp/app.py", true)
    {d, _} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})
    L.reset(sid)
    d.content
  end

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

    test "on a LARGE change the escape is honoured only from the second pushback",
         %{session_id: sid} do
      authored(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      assert L.change_scale(sid) == :large
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

    test "on a SMALL change the escape is honoured immediately", %{session_id: sid} do
      # Spending a whole round-trip to be told a one-line fix has no harness is
      # most of what the trivial case was paying for. The sentence is explicit
      # and logged, and it still cannot excuse never running anything — see the
      # next test.
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      assert L.change_scale(sid) == :small
      assert G.trigger(sid, 0, nil) == :inadequate_test
      assert G.trigger(sid, 0, "NO_RUNNABLE_TEST: no harness in this image") == nil
    end

    test "the escape cannot mask an outright unchecked write", %{session_id: sid} do
      edit(sid, "/tmp/app.py")

      assert G.trigger(sid, 2, "NO_RUNNABLE_TEST: nope") == :unchecked_write,
             "declaring no test possible does not excuse never running anything"
    end

    test "the gate asks ONCE and then steps aside, whatever the tier",
         %{session_id: sid} do
      # Measured: on `fix-code-vulnerability` and `feal-differential` the counter
      # ran 1 -> 2 -> 3, hit the cap, stepped aside unsatisfied, and both tasks
      # passed anyway. The second and third pushbacks converted nothing and cost
      # 37-41% of each task's tokens.
      authored(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      assert G.needs_verification?(%{session_id: sid, verification_gate_prompts: 0})
      refute G.needs_verification?(%{session_id: sid, verification_gate_prompts: 1})
    end

    test "…and the same for a small change", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      assert G.needs_verification?(%{session_id: sid, verification_gate_prompts: 0})
      refute G.needs_verification?(%{session_id: sid, verification_gate_prompts: 1})
    end
  end

  # ===========================================================================
  # Proportionality: the price is set by the size and shape of the change
  # ===========================================================================

  describe "change_scale/1" do
    test "no code change at all is :none", %{session_id: sid} do
      edit(sid, "/tmp/README.md")
      assert L.change_scale(sid) == :none
    end

    test "a one-site edit of a few lines is :small", %{session_id: sid} do
      L.record(sid, %{
        tool: "file_edit",
        args: %{"path" => "/tmp/app.py", "old_string" => "a\nb", "new_string" => "a\nc\nd"},
        success: true
      })

      assert L.change_scale(sid) == :small
    end

    test "authoring a whole file is :large however few lines it carries",
         %{session_id: sid} do
      L.record(sid, %{
        tool: "file_write",
        args: %{"path" => "/tmp/app.py", "content" => "x"},
        success: true
      })

      assert L.change_scale(sid) == :large,
             "writing the deliverable is not a tweak — this is the cancel-async-tasks shape"
    end

    test "a shell heredoc that creates the file is :large", %{session_id: sid} do
      sh(sid, "cat > /app/run.py << 'EOF'\nimport asyncio\nEOF", true)
      assert L.change_scale(sid) == :large
    end

    test "more than one code file is :large", %{session_id: sid} do
      edit(sid, "/tmp/a.py")
      edit(sid, "/tmp/b.py")
      assert L.change_scale(sid) == :large
    end

    test "a multi_file_edit is seen at all, and is :large", %{session_id: sid} do
      # `multi_file_edit` names its targets under `edits`; only `files` was
      # read, so a change spanning five files registered as touching none.
      L.record(sid, %{
        tool: "multi_file_edit",
        args: %{
          "edits" => [
            %{"path" => "/tmp/a.py", "old_string" => "x", "new_string" => "y"},
            %{"path" => "/tmp/b.py", "old_string" => "x", "new_string" => "y"}
          ]
        },
        success: true
      })

      assert L.changed_source_files(sid) == ["/tmp/a.py", "/tmp/b.py"]
      assert L.change_scale(sid) == :large
    end

    test "more than 20 changed lines in one file is :large", %{session_id: sid} do
      L.record(sid, %{
        tool: "file_edit",
        args: %{
          "path" => "/tmp/app.py",
          "old_string" => "a",
          "new_string" => String.duplicate("x\n", 30)
        },
        success: true
      })

      assert L.change_scale(sid) == :large
    end

    test "more than three edit calls is :large even if each is tiny", %{session_id: sid} do
      for _ <- 1..4, do: edit(sid, "/tmp/app.py")
      assert L.change_scale(sid) == :large
    end

    test "writes to test files do not count toward the change being measured",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      edit(sid, "/tmp/test_app.py")
      assert L.change_scale(sid) == :small
    end
  end

  describe "the gate must never ask for the working tree to be damaged" do
    test "no directive instructs reverting, stashing or un-fixing the source",
         %{session_id: sid} do
      # On `fix-code-vulnerability` the agent followed the old text literally,
      # twice: it reverted a CRLF-injection fix, re-introduced the vulnerability
      # into the file, ran the test red, then re-applied. It recovered both
      # times. Terminal-Bench grades final machine state, so an agent killed
      # mid-cycle on a timeout-bound task ships the vulnerable version.
      for setup <- [&authored/2, &edit/2] do
        s = "revert-#{System.unique_integer([:positive])}"
        L.reset(s)
        setup.(s, "/tmp/app.py")
        sh(s, "python3 -m py_compile /tmp/app.py", true)

        {d, _} = G.build_directive(%{session_id: s, verification_gate_prompts: 0})
        text = String.downcase(d.content)

        refute text =~ "revert the fix"
        refute text =~ "restore the fix"
        refute text =~ "git stash"
        refute text =~ "undo your"
        L.reset(s)
      end
    end

    test "the large directive says so explicitly", %{session_id: sid} do
      authored(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      {d, _} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})

      assert d.content =~ "NEVER un-fix working code"
      assert d.content =~ "Do not manufacture a failure."
    end
  end

  describe "the gate must recognise the evidence it demanded" do
    test "a node-id re-run and a plain run are the SAME recurring check",
         %{session_id: sid} do
      # The natural way to re-run one failing case is a node id. It carried no
      # path token that survived, so that run formed only a suite identity while
      # the plain run formed only a file identity, and red under one never paired
      # with green under the other: the agent produced exactly the sequence the
      # gate asked for and the gate asked again.
      ws = Path.join(System.tmp_dir!(), "osa-nodeid-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(ws, "tests"))
      OptimalSystemAgent.Workspace.Cwd.put_session_dir(sid, ws)
      on_exit(fn -> File.rm_rf(ws) end)

      sh(sid, "cat > app.py << 'EOF'\nx\nEOF", true)
      sh(sid, "cat > tests/test_app.py << 'EOF'\nimport app\nEOF", true)
      sh(sid, "pytest tests/test_app.py::test_crlf", false)
      sh(sid, "cat > app.py << 'EOF'\ny\nEOF", true)
      sh(sid, "pytest tests/test_app.py", true)

      assert L.discriminating_evidence(sid),
             "red on the node id and green on the file is one test, run twice"

      refute L.needs_discriminating_test?(sid)
    end

    test "a restore by `cp` is a source write, so it can bracket red and green",
         %{session_id: sid} do
      sh(sid, "cat > /tmp/app.py << 'EOF'\nx\nEOF", true)
      sh(sid, "cat > /tmp/test_app.py << 'EOF'\nimport app\nEOF", true)
      sh(sid, "python3 /tmp/test_app.py", false)
      sh(sid, "cp /tmp/app_fixed.py /tmp/app.py", true)
      sh(sid, "python3 /tmp/test_app.py", true)

      assert "/tmp/app.py" in L.changed_source_files(sid)
      assert %{artifact: {:file, "/tmp/test_app.py"}} = L.discriminating_evidence(sid)
    end

    test "two inline heredocs mentioning pytest still form NO suite identity",
         %{session_id: sid} do
      # Emitting the suite identity alongside file identities would otherwise
      # let a throwaway heredoc that merely MENTIONS a runner pair red with
      # green. This hole predates the change; it stays closed.
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 - << 'PY'\nimport pytest\nassert 0\nPY", false)
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 - << 'PY'\nimport pytest\nassert 1\nPY", true)

      assert L.needs_discriminating_test?(sid)
    end

    test "`python3 -c 'import pytest'` forms no suite identity either",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 -c \"import pytest; assert 0\"", false)
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 -c \"import pytest; assert 1\"", true)

      assert L.needs_discriminating_test?(sid)
    end
  end

  describe "the kill switch covers the WHOLE feature" do
    test "the early nudge is silenced by OSA_VERIFICATION_ADEQUACY=0",
         %{session_id: sid} do
      # It was not, and it fired in both arms of the ablation, so the measured
      # cost priced the pushback and not the feature.
      edit(sid, "/tmp/app.py")
      assert G.first_write_nudge(sid)

      System.put_env("OSA_VERIFICATION_ADEQUACY", "0")
      on_exit(fn -> System.delete_env("OSA_VERIFICATION_ADEQUACY") end)

      refute G.first_write_nudge(sid)
    end
  end

  describe "every edit tool OSA actually ships is a write" do
    test "file_transform fixes are visible, so a triple can form around them",
         %{session_id: sid} do
      # Measured live: the model authored a module, wrote a real test file, and
      # iterated red -> fix -> green four times through `file_transform`. Its
      # name contains neither "write" nor "edit" nor "patch", so it classified
      # as `:other`, not one of those fixes was recorded, no triple could form,
      # and the gate demanded the work it had just watched happen.
      sh(sid, "cat > /tmp/app.py << 'EOF'\nx\nEOF", true)
      sh(sid, "cat > /tmp/test_app.py << 'EOF'\nimport app\nEOF", true)
      sh(sid, "python3 /tmp/test_app.py", false)

      L.record(sid, %{
        tool: "file_transform",
        args: %{
          "path" => "/tmp/app.py",
          "operations" => [%{"op" => "replace", "find" => "x", "to" => "y"}]
        },
        success: true
      })

      sh(sid, "python3 /tmp/test_app.py", true)

      assert "/tmp/app.py" in L.changed_source_files(sid)
      assert %{artifact: {:file, "/tmp/test_app.py"}} = L.discriminating_evidence(sid)
      refute L.needs_discriminating_test?(sid)
    end

    test "a file_transform of a few lines is still a :small change", %{session_id: sid} do
      L.record(sid, %{
        tool: "file_transform",
        args: %{
          "path" => "/tmp/app.py",
          "operations" => [%{"op" => "replace", "find" => "x", "to" => "y\nz"}]
        },
        success: true
      })

      assert L.change_scale(sid) == :small
    end
  end

  describe "a test invoked by RELATIVE path is still the same test" do
    test "red -> source fix -> green counts when the model never types an absolute path",
         %{session_id: sid} do
      # Measured live: the model wrote `tests/test_ratelimit.py`, ran it red,
      # fixed the source, ran it green — and every invocation was stored against
      # the OSA process's own cwd, a file that does not exist. No identity
      # formed, so the gate demanded the work that had just been done, three
      # times, until the cap released it. A gate nobody can satisfy is pure cost.
      ws = Path.join(System.tmp_dir!(), "osa-relpath-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(ws, "tests"))
      OptimalSystemAgent.Workspace.Cwd.put_session_dir(sid, ws)
      on_exit(fn -> File.rm_rf(ws) end)

      sh(sid, "cat > app.py << 'EOF'\nx\nEOF", true)
      sh(sid, "cat > tests/test_app.py << 'EOF'\nimport app\nEOF", true)
      sh(sid, "python3 tests/test_app.py", false)
      sh(sid, "cat > app.py << 'EOF'\ny\nEOF", true)
      sh(sid, "python3 tests/test_app.py", true)

      assert L.changed_source_files(sid) == [Path.join(ws, "app.py")]

      assert %{artifact: {:file, path}} = L.discriminating_evidence(sid)
      assert path == Path.join(ws, "tests/test_app.py")

      refute L.needs_discriminating_test?(sid)
    end

    test "a `cd <dir> &&` prefix wins over the session workspace", %{session_id: sid} do
      OptimalSystemAgent.Workspace.Cwd.put_session_dir(sid, "/workspace")
      sh(sid, "cd /app && python3 tests/test_x.py", false)

      assert "/app/tests/test_x.py" in (L.entries(sid) |> List.last() |> Map.get(:ran_paths))
    end
  end

  describe "external_suite_pass?/1 — the project's own suite, not the model's" do
    test "a green project suite after the last source write counts", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "pytest", true)
      assert L.external_suite_pass?(sid)
    end

    test "a suite run BEFORE the last source write does not", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "pytest", true)
      edit(sid, "/tmp/app.py")
      refute L.external_suite_pass?(sid)
    end

    test "a red suite does not", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "pytest", false)
      refute L.external_suite_pass?(sid)
    end

    test "a suite the session partly WROTE does not — that is the original attack",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "cat > tests/test_mine.py << 'EOF'\nassert True\nEOF", true)
      sh(sid, "pytest", true)

      refute L.external_suite_pass?(sid),
             "authoring a passing test into the suite must not launder it into external evidence"

      assert L.needs_discriminating_test?(sid)
    end

    test "a suite run with a narrowing flag does not", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "pytest --ignore=tests/test_hard.py", true)
      refute L.external_suite_pass?(sid)
    end

    test "removing a test file disables the shortcut for the rest of the session",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "rm tests/test_hard.py", true)
      sh(sid, "pytest", true)

      refute L.external_suite_pass?(sid),
             "a suite made green by deleting what was red is not a green suite"
    end

    test "a build is not a suite", %{session_id: sid} do
      edit(sid, "/tmp/app.go")
      sh(sid, "go build ./...", true)
      refute L.external_suite_pass?(sid)
    end

    test "an inline probe is not a suite", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 - << 'PY'\nimport app\nPY", true)
      refute L.external_suite_pass?(sid)
    end
  end

  describe "the tier decides what discharges adequacy" do
    test "small change + green project suite completes", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "./run_tests.sh", true)

      refute G.needs_verification?(%{session_id: sid, verification_gate_prompts: 0}),
             "the cheapest strong evidence available, and it costs no extra turns"
    end

    test "large change + green project suite still blocks", %{session_id: sid} do
      authored(sid, "/tmp/app.py")
      sh(sid, "./run_tests.sh", true)

      assert G.trigger(sid, 0, nil) == :inadequate_test,
             "a pre-existing suite proves no regression, not that new behaviour works"
    end

    test "a small change still may not finish on NOTHING having run", %{session_id: sid} do
      edit(sid, "/tmp/app.py")

      assert G.trigger(sid, 0, "NO_RUNNABLE_TEST: nope") == :unchecked_write,
             "the liveness clause is tier-blind"
    end

    test "a small change still may not finish on a RED check", %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "pytest", false)

      assert G.trigger(sid, 0, "NO_RUNNABLE_TEST: nope") == :failing_check
    end

    test "the kill switch still turns the whole adequacy clause off", %{session_id: sid} do
      authored(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      assert G.trigger(sid, 0, nil) == :inadequate_test

      System.put_env("OSA_VERIFICATION_ADEQUACY", "0")
      on_exit(fn -> System.delete_env("OSA_VERIFICATION_ADEQUACY") end)

      assert G.trigger(sid, 0, nil) == nil
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

    test "the LARGE adequacy directive states all three properties and the escape",
         %{session_id: sid} do
      authored(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      {d, st} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})

      assert d.content =~ "PERSISTED"
      assert d.content =~ "RE-RUNNABLE"
      assert d.content =~ "FAILED AT LEAST ONCE"
      assert d.content =~ "NO_RUNNABLE_TEST"
      assert st.verification_gate_prompts == 1
    end

    test "the SMALL directive asks for the existing suite first, and is short",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)

      {d, _} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})

      assert d.content =~ "already has a test suite"
      assert d.content =~ "NO_RUNNABLE_TEST"

      refute d.content =~ "FAILED AT LEAST ONCE",
             "a one-site edit does not buy a hand-built red -> fix -> green cycle"

      assert byte_size(d.content) < byte_size(large_directive()),
             "the cheap case must not pay the expensive case's prompt"
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

  # ===========================================================================
  # Species 6 — the gate's own test file must not become part of the deliverable
  # ===========================================================================
  #
  # `polyglot-c-py` and `polyglot-rust-c` were both lost on the FIRST line of
  # their verifier — `assert os.listdir(...) == ["main.rs"]` — against a
  # directory holding OSA's persisted test file, its `__pycache__` and the
  # binaries the test compiled. All three are artefacts this gate asked for.
  describe "keeps its test artefacts out of the deliverable directory" do
    test "the early nudge names a scratch location and says not to sit beside the work",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      nudge = G.first_write_nudge(sid)

      assert nudge =~ "/tmp/osa-tests/"
      assert nudge =~ "never beside the files the task asked"
      assert nudge =~ "__pycache__"
    end

    test "the large directive names the same scratch location", %{session_id: sid} do
      authored(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)
      {d, _} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})

      assert d.content =~ "/tmp/osa-tests/"
      assert d.content =~ "NEVER in the directory that holds the deliverable"
      assert d.content =~ "PYTHONDONTWRITEBYTECODE=1"
    end

    test "the small directive says it too, without growing into the large one",
         %{session_id: sid} do
      edit(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)
      {d, _} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})

      assert d.content =~ "/tmp/osa-tests/"
      assert byte_size(d.content) < byte_size(large_directive())
    end

    test "a test written where the directive says to put it still counts as evidence",
         %{session_id: sid} do
      # The failure mode this guards: the gate prescribes a location whose files
      # match none of its own basename patterns, and then refuses the evidence it
      # asked for. `check_polyglot.py` is not `test_*.py`; the directory is what
      # makes it a test artefact.
      authored(sid, "/app/polyglot/main.rs")
      sh(sid, "cat > /tmp/osa-tests/check_polyglot.py << 'EOF'\nx\nEOF", true)
      sh(sid, "python3 /tmp/osa-tests/check_polyglot.py", false)
      authored(sid, "/app/polyglot/main.rs")
      sh(sid, "python3 /tmp/osa-tests/check_polyglot.py", true)

      assert L.test_artifact_path?("/tmp/osa-tests/check_polyglot.py")
      assert "/tmp/osa-tests/check_polyglot.py" in L.known_test_artifacts(sid)

      assert %{artifact: {:file, "/tmp/osa-tests/check_polyglot.py"}} =
               L.discriminating_evidence(sid)

      refute L.needs_discriminating_test?(sid)
    end
  end

  # ===========================================================================
  # Species 2 — the self-authored oracle tested the wrong thing
  # ===========================================================================
  #
  # There is no detector for this (see `docs/research/failure-taxonomy.md` §2.4:
  # every episode-shape proxy fires on the solves too). What the gate can do is
  # spend the pushback it was already spending on the correspondence between the
  # test and the TASK rather than on the mechanics of the test. These assertions
  # pin that the ask is present, that it costs no extra pushback, and that the
  # provenance observation is factual.
  describe "asks what the test checks, not only whether it discriminates" do
    test "the large directive asks for requirement-by-requirement coverage",
         %{session_id: sid} do
      authored(sid, "/tmp/app.py")
      sh(sid, "python3 -m py_compile /tmp/app.py", true)
      {d, st} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})

      assert d.content =~ "proves only the proposition IT states"
      assert d.content =~ "name the assertion that checks it"
      assert d.content =~ "DIRECTION"
      assert d.content =~ "THAT is the oracle"

      assert d.content =~ "testing your test",
             "torch-tensor-parallelism's test performed the all-gather under test"

      assert st.verification_gate_prompts == 1,
             "re-aiming the pushback must not add one"
    end

    test "says so when nothing but the session's own files has ever run",
         %{session_id: sid} do
      authored(sid, "/tmp/app.py")
      sh(sid, "cat > /tmp/osa-tests/test_app.py << 'EOF'\nx\nEOF", true)
      sh(sid, "python3 /tmp/osa-tests/test_app.py", true)

      assert L.oracle_provenance(sid) == :self_authored
      {d, _} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})
      assert d.content =~ "nothing you did not author has had the chance to disagree"
    end

    test "and stays quiet about it once something external has run",
         %{session_id: sid} do
      authored(sid, "/tmp/app.py")
      # A suite the session did not write.
      sh(sid, "pytest tests/", true)

      assert L.oracle_provenance(sid) == :external
      {d, _} = G.build_directive(%{session_id: sid, verification_gate_prompts: 0})
      refute d.content =~ "nothing you did not author has had the chance to disagree"
    end

    test "provenance is :none when every check was a throwaway snippet",
         %{session_id: sid} do
      authored(sid, "/tmp/app.py")
      sh(sid, "python3 - << 'PY'\nimport app\nPY", true)
      sh(sid, "python3 -c \"import app\"", true)

      assert L.oracle_provenance(sid) == :none
    end

    test "the provenance rides on the observable gate event", %{session_id: sid} do
      me = self()

      ref =
        OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn ev ->
          if is_map(ev.data) and ev.data[:event] == :verification_gate_triggered,
            do: send(me, {:gate, ev.data})
        end)

      on_exit(fn -> OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, ref) end)

      authored(sid, "/tmp/app.py")
      sh(sid, "cat > /tmp/osa-tests/test_app.py << 'EOF'\nx\nEOF", true)
      sh(sid, "python3 /tmp/osa-tests/test_app.py", true)
      G.build_directive(%{session_id: sid, verification_gate_prompts: 0})

      assert_receive {:gate, %{oracle: :self_authored}}, 2_000
    end
  end
end
