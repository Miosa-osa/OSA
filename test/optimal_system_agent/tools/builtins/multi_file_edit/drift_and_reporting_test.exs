defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit.DriftAndReportingTest do
  @moduledoc """
  Two more `multi_file_edit` defects from finding 4:

    * it called `FileState.check_read/2` but never `DriftGuard` (unlike
      `FileEdit.Handler`), so it computed new content from a read taken earlier
      and wrote it over whatever was on disk;
    * `rollback/1` discarded every `File.write` result while the caller reported
      "all changes rolled back, no files were modified" unconditionally.

  Both tests fail against the pre-fix tree.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuard
  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Handler
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    FileState.reset()
    DriftGuard.reset()

    dir = Path.join(System.tmp_dir!(), "osa_mfe_drift_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp edit(path, old, new), do: %{"path" => path, "old_string" => old, "new_string" => new}
  defp run(edits, ctx), do: Handler.execute(%{"edits" => edits}, ctx)

  test "content drift under an identical {mtime, size} is rejected", %{dir: dir} do
    session = "mfe-drift-#{System.unique_integer([:positive])}"
    ctx = %UseContext{session_id: session}
    path = Path.join(dir, "drift.ex")

    File.write!(path, "one\ntwo\nthree\n")
    FileState.record_read(session, path)

    # A first successful edit establishes the DriftGuard baseline.
    assert {:ok, _, _} = run([edit(path, "two", "TWO")], ctx)
    %File.Stat{mtime: mtime, size: size} = File.stat!(path, time: :posix)

    # A concurrent writer (formatter-on-save, sibling agent) lands DIFFERENT
    # content on the same wall-clock second and the same byte count — precisely
    # the window `FileState`'s {mtime, size} comparison cannot see, which is why
    # `file_edit` runs DriftGuard as an independent second layer.
    drifted = String.pad_trailing("1\nDR\nthree\n", size, " ")
    assert byte_size(drifted) == size
    File.write!(path, drifted)
    File.touch!(path, mtime)

    assert {:error, message} = run([edit(path, "three", "THREE")], ctx)
    assert message =~ "changed since you read it"

    # The concurrent writer's content is still there — not silently discarded.
    assert File.read!(path) == drifted
  end

  test "an unwritable target aborts the batch before anything is written", %{dir: dir} do
    ctx = %UseContext{session_id: "test"}

    good = Path.join(dir, "good.ex")
    File.write!(good, "one\n")

    # A directory can never be written as a file.
    bad = Path.join(dir, "bad.ex")
    File.mkdir_p!(bad)
    File.write!(Path.join(bad, "inner"), "x")

    assert {:error, message} = run([edit(good, "one", "ONE"), edit(bad, "one", "ONE")], ctx)

    # The caller's unconditional "all changes rolled back, no files were
    # modified" is gone; the claim now comes from the phase that knows whether
    # it is true, and here it genuinely is.
    refute message =~ "all changes rolled back"
    assert message =~ "no files were modified"
    assert File.read!(good) == "one\n"
  end
end
