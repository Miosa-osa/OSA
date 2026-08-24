defmodule OptimalSystemAgent.Tools.RefreshWriteBaselineTest do
  @moduledoc """
  Bug 4: a :file_changed hook that reformats a file after a write left the
  read-before-edit / drift baseline pointing at the pre-format bytes, so the
  NEXT edit was falsely rejected with "re-read the file first" — the churn
  users hit under rapid edits with a format-on-save hook. refresh_write_baseline
  re-captures from the final on-disk bytes; these tests pin that.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_rwb_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    # A concrete (non-exempt) session so read-before-edit enforcement is live.
    {:ok, dir: dir, session: "sess-#{System.unique_integer([:positive])}"}
  end

  test "a formatter rewrite after a write does NOT leave the next edit flagged stale",
       %{dir: dir, session: session} do
    path = Path.join(dir, "m.ts")
    File.write!(path, "const x=1\n")

    # The tool records the baseline from what it wrote.
    FileState.record_write(session, path)
    assert FileState.check_read(session, path) == :ok

    # A :file_changed formatter hook rewrites the file (different bytes/size).
    # Force a distinct mtime granule so the staleness check would trip.
    File.write!(path, "const x = 1;\n")
    stat = File.stat!(path, time: :posix)
    File.touch!(path, stat.mtime + 2)

    # Without a refresh this is now stale. The fix re-captures the baseline.
    assert {:error, _} = FileState.check_read(session, path),
           "precondition: the post-format file is stale versus the pre-format baseline"

    assert :ok = Handler.refresh_write_baseline(session, path)
    assert FileState.check_read(session, path) == :ok,
           "after refresh, the next edit must not be falsely flagged stale"
  end

  test "refresh on a vanished file is a harmless no-op", %{dir: dir, session: session} do
    path = Path.join(dir, "gone.ts")
    assert :ok = Handler.refresh_write_baseline(session, path)
  end
end
