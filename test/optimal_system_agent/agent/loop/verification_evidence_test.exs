defmodule OptimalSystemAgent.Agent.Loop.VerificationEvidenceTest do
  @moduledoc """
  P1-3: the grounded verification gate must require real, passing evidence that
  touches the changed file — not merely "a read/test/shell-named tool appeared".
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: Ledger
  alias OptimalSystemAgent.Agent.Loop.VerificationGate

  setup do
    sid = "verif-test-#{System.unique_integer([:positive])}"
    Ledger.reset(sid)
    on_exit(fn -> Ledger.reset(sid) end)
    {:ok, session_id: sid, path: Path.expand("/tmp/osa_verif_#{sid}.ex")}
  end

  defp write(sid, path, success \\ true) do
    Ledger.record(sid, %{tool: "file_edit", args: %{"path" => path}, success: success})
  end

  defp read(sid, path, success \\ true) do
    Ledger.record(sid, %{tool: "file_read", args: %{"path" => path}, success: success})
  end

  defp shell(sid, command, success) do
    Ledger.record(sid, %{tool: "shell_execute", args: %{"command" => command}, success: success})
  end

  describe "verification PASSES with real grounded evidence" do
    test "a passing project build/test after the write verifies the changed file",
         %{session_id: sid, path: path} do
      write(sid, path)
      refute Ledger.verified?(sid)

      shell(sid, "mix compile", true)
      assert Ledger.verified?(sid)
      assert Ledger.pending_files(sid) == []
    end

    test "a re-read does NOT verify the edit — it only reports what the file says",
         %{session_id: sid, path: path} do
      # This asserted the opposite, and that was the defect.
      #
      # Reads were classified as checks, so re-reading a file discharged the
      # pending write to it. Worse, the gate's own directive ADVERTISES
      # re-reading as a way to satisfy it, while `file_edit`'s prompt
      # simultaneously says "do NOT re-read the file to verify an edit that
      # succeeded" — so the gate was teaching the model how to defeat it, in
      # direct contradiction of another prompt.
      #
      # A read reports what a file SAYS. Verification is about whether it
      # WORKS, which requires running something that can fail.
      write(sid, path)
      read(sid, path, true)
      refute Ledger.verified?(sid)
      assert Ledger.pending_files(sid) == [path]
    end

    test "a failing check since the last write is its own signal" do
      # The other half, and the one every harness studied was missing: this
      # ledger recorded `success: false` for a red test and the loop discarded
      # it. Gating only on the ABSENCE of verification means a failure answers
      # "was it checked?" with yes.
      sid = "verif-fail-#{System.unique_integer([:positive])}"
      Ledger.record(sid, %{tool: "file_edit", args: %{"path" => "/tmp/x.ex"}, success: true})
      assert Ledger.failing_check_since_write(sid) == nil

      Ledger.record(sid, %{
        tool: "shell_execute",
        args: %{"command" => "pytest t.py"},
        success: false
      })

      assert %{} = Ledger.failing_check_since_write(sid)
    end

    test "a build passing is not a test passing" do
      # `go build` succeeding used to discharge an edit whose test was red,
      # because build and test were one predicate.
      sid = "verif-build-#{System.unique_integer([:positive])}"
      Ledger.record(sid, %{tool: "file_edit", args: %{"path" => "/tmp/x.go"}, success: true})

      Ledger.record(sid, %{
        tool: "shell_execute",
        args: %{"command" => "go build ./..."},
        success: true
      })

      refute Ledger.tested_since_write?(sid)

      Ledger.record(sid, %{
        tool: "shell_execute",
        args: %{"command" => "go test ./..."},
        success: true
      })

      assert Ledger.tested_since_write?(sid)
    end

    test "the harness's own run_tests.sh registers as a test" do
      # It matched none of the eight original patterns, so the single most
      # authoritative check available counted as nothing.
      assert Ledger.test_command?(%{"command" => "./run_tests.sh"})
      assert Ledger.test_command?(%{"command" => "bash /testbed/run_tests.sh"})
    end

    test "a shell command that references the changed file's basename verifies it",
         %{session_id: sid, path: path} do
      write(sid, path)
      shell(sid, "elixir #{Path.basename(path)}", true)
      assert Ledger.verified?(sid)
    end
  end

  describe "verification FAILS on spoof / missing evidence" do
    test "an unrelated read does NOT verify the changed file",
         %{session_id: sid, path: path} do
      write(sid, path)
      # Read a DIFFERENT file — the classic spoof.
      read(sid, Path.expand("/tmp/some_other_file.ex"), true)

      refute Ledger.verified?(sid)
      assert Ledger.pending_files(sid) == [path]
    end

    test "a FAILED check (non-zero exit) does NOT verify the changed file",
         %{session_id: sid, path: path} do
      write(sid, path)
      shell(sid, "mix compile", false)

      refute Ledger.verified?(sid)
      assert path in Ledger.pending_files(sid)
    end

    test "a check that ran BEFORE the write does not count",
         %{session_id: sid, path: path} do
      shell(sid, "mix compile", true)
      write(sid, path)

      refute Ledger.verified?(sid)
    end

    test "a re-write after a passing check re-opens the pending state",
         %{session_id: sid, path: path} do
      write(sid, path)
      shell(sid, "mix compile", true)
      assert Ledger.verified?(sid)

      # Model edits again but never re-checks.
      write(sid, path)
      refute Ledger.verified?(sid)
    end
  end

  describe "gate integration" do
    test "needs_verification? fires only when evidence is missing",
         %{session_id: sid, path: path} do
      state = %{session_id: sid, verification_gate_prompts: 0}

      # No writes yet — nothing to verify.
      refute VerificationGate.needs_verification?(state)

      write(sid, path)
      assert VerificationGate.needs_verification?(state)

      # A passing suite run discharges the LIVENESS question…
      shell(sid, "mix test", true)
      assert Ledger.verified?(sid)

      # …and, because this is a one-site edit, the ADEQUACY one too: the
      # project's own suite is evidence the session did not author, so a green
      # run of it is proportionate proof that a small edit regressed nothing.
      assert Ledger.change_scale(sid) == :small
      assert VerificationGate.trigger(sid, 0, nil) == nil
      refute VerificationGate.needs_verification?(state)
    end

    test "a green project suite does NOT discharge adequacy for a large change",
         %{session_id: sid, path: path} do
      # Authoring a file is never `:small`, so "the suite still passes" is not
      # the claim at issue and does not buy completion. See
      # `VerificationAdequacyTest` for the full account.
      Ledger.record(sid, %{
        tool: "file_write",
        args: %{"path" => path, "content" => String.duplicate("x\n", 60)},
        success: true
      })

      shell(sid, "mix test", true)

      assert Ledger.change_scale(sid) == :large
      assert VerificationGate.trigger(sid, 0, nil) == :inadequate_test

      # Red -> source fix -> green is what discharges it.
      shell(sid, "mix test", false)
      write(sid, path)
      shell(sid, "mix test", true)

      refute VerificationGate.needs_verification?(%{
               session_id: sid,
               verification_gate_prompts: 0
             })
    end

    test "gate steps aside after the re-prompt cap even with pending evidence",
         %{session_id: sid, path: path} do
      write(sid, path)
      capped = %{session_id: sid, verification_gate_prompts: 3}
      refute VerificationGate.needs_verification?(capped)
    end

    test "build_directive names the pending file and advances the counter",
         %{session_id: sid, path: path} do
      write(sid, path)
      state = %{session_id: sid, verification_gate_prompts: 0}

      {directive, new_state} = VerificationGate.build_directive(state)

      # `user`, not `system`: Anthropic and Gemini reject a system message that
      # follows assistant TEXT with a 400, which made this gate a no-op on
      # those families. The steer is an instruction injected into the
      # conversation, not part of the system prompt.
      assert directive.role == "user"
      assert directive.content =~ path
      assert directive.content =~ "VERIFICATION REQUIRED"
      assert new_state.verification_gate_prompts == 1
    end
  end
end
