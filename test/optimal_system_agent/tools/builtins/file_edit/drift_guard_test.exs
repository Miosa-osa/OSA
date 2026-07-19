defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuardTest do
  @moduledoc """
  Unit coverage for the hashline-style content-drift guard (P1 #6 / U-A2).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuard

  setup do
    DriftGuard.reset()
    :ok
  end

  describe "fingerprint/1 normalization" do
    test "is stable across CRLF vs LF" do
      assert DriftGuard.fingerprint("a\r\nb\r\nc\r\n") == DriftGuard.fingerprint("a\nb\nc\n")
    end

    test "ignores trailing whitespace per line" do
      assert DriftGuard.fingerprint("a  \nb\t\nc\n") == DriftGuard.fingerprint("a\nb\nc\n")
    end

    test "differs when actual line content changes" do
      refute DriftGuard.fingerprint("a\nb\nc\n") == DriftGuard.fingerprint("a\nB\nc\n")
    end
  end

  describe "verify/5 and record/5" do
    test "first touch for a path in a session has no baseline — allowed" do
      assert :ok == DriftGuard.verify("sess-1", "/tmp/whatever.txt", "hello\n", 100, 6)
    end

    test "matching {mtime, size, content} after a record passes" do
      DriftGuard.record("sess-1", "/tmp/whatever.txt", "hello\n", 100, 6)
      assert :ok == DriftGuard.verify("sess-1", "/tmp/whatever.txt", "hello\n", 100, 6)
    end

    test "identical {mtime, size} but different content is rejected with a re-read message" do
      DriftGuard.record("sess-1", "/tmp/whatever.txt", "hello\n", 100, 6)

      # Same mtime, same size (padded to match) — the aliasing collision
      # FileState's own {mtime, size} check cannot see.
      assert {:error, msg} =
               DriftGuard.verify("sess-1", "/tmp/whatever.txt", "goodb\n", 100, 6)

      assert msg =~ "changed since you read it"
      assert msg =~ "re-read and retry"
    end

    test "identical raw content at the same {mtime, size} passes (no false positive)" do
      DriftGuard.record("sess-1", "/tmp/whatever.txt", "hello\nworld\n", 100, 12)

      assert :ok ==
               DriftGuard.verify("sess-1", "/tmp/whatever.txt", "hello\nworld\n", 100, 12)
    end

    test "different {mtime, size} than the baseline defers to FileState (never blocks)" do
      DriftGuard.record("sess-1", "/tmp/whatever.txt", "hello\n", 100, 6)

      # The file's identity moved on (different mtime/size) — DriftGuard
      # steps aside regardless of content, even wildly different content,
      # because it never observes file_read and must not create a lockout.
      assert :ok ==
               DriftGuard.verify("sess-1", "/tmp/whatever.txt", "totally different\n", 200, 18)
    end

    test "sessions are isolated from each other" do
      DriftGuard.record("sess-1", "/tmp/whatever.txt", "hello\n", 100, 6)
      # sess-2 has never touched this path — no baseline, allowed regardless.
      assert :ok ==
               DriftGuard.verify("sess-2", "/tmp/whatever.txt", "totally different\n", 100, 6)
    end

    test "nil and \"test\" sentinel sessions are exempt" do
      DriftGuard.record(nil, "/tmp/whatever.txt", "hello\n", 100, 6)
      assert :ok == DriftGuard.verify(nil, "/tmp/whatever.txt", "anything at all\n", 100, 6)

      DriftGuard.record("test", "/tmp/whatever.txt", "hello\n", 100, 6)
      assert :ok == DriftGuard.verify("test", "/tmp/whatever.txt", "anything at all\n", 100, 6)
    end
  end
end
