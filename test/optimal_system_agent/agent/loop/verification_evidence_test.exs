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

    test "a passing re-read of the changed file itself verifies it",
         %{session_id: sid, path: path} do
      write(sid, path)
      read(sid, path, true)
      assert Ledger.verified?(sid)
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

      shell(sid, "mix test", true)
      refute VerificationGate.needs_verification?(state)
    end

    test "gate steps aside after the re-prompt cap even with pending evidence",
         %{session_id: sid, path: path} do
      write(sid, path)
      capped = %{session_id: sid, verification_gate_prompts: 2}
      refute VerificationGate.needs_verification?(capped)
    end

    test "build_directive names the pending file and advances the counter",
         %{session_id: sid, path: path} do
      write(sid, path)
      state = %{session_id: sid, verification_gate_prompts: 0}

      {directive, new_state} = VerificationGate.build_directive(state)

      assert directive.role == "system"
      assert directive.content =~ path
      assert directive.content =~ "VERIFICATION REQUIRED"
      assert new_state.verification_gate_prompts == 1
    end
  end
end
