defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuardIntegrationTest do
  @moduledoc """
  End-to-end coverage of the drift guard (P1 #6 / U-A2) through
  `FileEdit.Handler`, layered on top of `FileState`'s existing
  read-before-edit / mtime-size stale-write check.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuard
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEdit
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: FileRead
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    FileState.reset()
    DriftGuard.reset()
    sid = "drift-guard-#{System.unique_integer([:positive])}"
    ctx = %UseContext{session_id: sid, permission_tier: :full}
    path = Path.join(System.tmp_dir!(), "osa_drift_#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(path) end)
    {:ok, ctx: ctx, path: path}
  end

  defp edit(path, old, new, ctx),
    do: FileEdit.execute(%{"path" => path, "old_string" => old, "new_string" => new}, ctx)

  test "a clean edit still applies (bootstrap + verified baseline)", %{ctx: ctx, path: path} do
    File.write!(path, "one\ntwo\nthree\n")
    assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

    # First edit to this path in the session — DriftGuard has no baseline yet
    # (bootstrap), FileState's read-before-edit passes.
    assert :ok == edit(path, "two", "TWO", ctx) |> elem(0)
    assert File.read!(path) == "one\nTWO\nthree\n"

    # Second edit — no intervening file_read, but nothing else touched the
    # file either, so both FileState's refreshed tracker and DriftGuard's
    # baseline (recorded after edit #1) agree — still applies cleanly.
    assert :ok == edit(path, "three", "THREE", ctx) |> elem(0)
    assert File.read!(path) == "one\nTWO\nTHREE\n"
  end

  test "a drifted edit is rejected with the re-read error, even when FileState's mtime/size check would miss it",
       %{ctx: ctx, path: path} do
    File.write!(path, "one\ntwo\nthree\n")
    assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

    # First edit — establishes both FileState's tracker and DriftGuard's
    # content-hash baseline.
    assert :ok == edit(path, "two", "TWO", ctx) |> elem(0)
    %File.Stat{mtime: mtime, size: size} = File.stat!(path, time: :posix)

    # Simulate the race DriftGuard exists for: some other process (a
    # linter-on-save, a concurrent sub-agent, a hook) rewrites the file with
    # DIFFERENT real content but happens to land on the exact same mtime
    # (sub-second write, same wall-clock second) and — by padding — the same
    # byte size. FileState's {mtime, size} check alone cannot see this.
    drifted = String.pad_trailing("one\nDRIFTED\nthree", size, " ") <> "\n"
    drifted = binary_part(drifted, 0, size)
    assert byte_size(drifted) == size

    File.write!(path, drifted)
    File.touch!(path, mtime)

    # FileState alone would allow this (identical mtime/size to what it
    # recorded after edit #1) — DriftGuard's content fingerprint catches the
    # real content change and rejects with a clear re-read instruction.
    assert {:error, msg} = edit(path, "three", "THREE", ctx)
    assert msg =~ "changed since you read it"
    assert msg =~ "re-read and retry"

    # The rejected edit must not have modified the file.
    assert File.read!(path) == drifted
  end

  test "re-reading after real drift clears the guard for the next edit", %{ctx: ctx, path: path} do
    File.write!(path, "alpha\nbeta\n")
    assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)
    assert :ok == edit(path, "beta", "BETA", ctx) |> elem(0)

    # External modification with a real mtime/size delta — FileState's own
    # guard rejects this one (belt-and-suspenders, unaffected by DriftGuard).
    File.write!(path, "alpha\nBETA\nEXTRA\n")
    File.touch!(path, {{2035, 1, 1}, {0, 0, 0}})
    assert {:error, _} = edit(path, "BETA", "beta", ctx)

    # Re-read refreshes FileState; DriftGuard also gets a fresh baseline the
    # next time this path is edited in the session.
    assert {:ok, _} = FileRead.execute(%{"path" => path}, ctx)
    assert :ok == edit(path, "BETA", "beta", ctx) |> elem(0)
    assert File.read!(path) == "alpha\nbeta\nEXTRA\n"
  end
end
