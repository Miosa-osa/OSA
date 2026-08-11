defmodule OptimalSystemAgent.Shell.TaskOutputRetentionTest do
  @moduledoc """
  Bounds tests for background-task output files (`<tmp>/osa/<session>/tasks/*.out`).

  Before this, nothing in the shell subsystem ever removed one of these files.
  Three mechanisms bound them now, and each is asserted here as a BOUND (drive N
  tasks, assert the file count stops growing), not just as "the function works":

    * `delete/2` — retirement of a single task's file,
    * `sweep_session/2` — per-session count cap enforced on task start,
    * `sweep_orphans/1` — boot sweep of a dead daemon's leftovers.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Shell.TaskOutput

  defp tasks_dir(sid) do
    Path.join([System.tmp_dir!(), "osa", Regex.replace(~r/[^A-Za-z0-9._-]/, sid, "_"), "tasks"])
  end

  defp out_count(sid) do
    case File.ls(tasks_dir(sid)) do
      {:ok, fs} -> Enum.count(fs, &String.ends_with?(&1, ".out"))
      _ -> 0
    end
  end

  # Backdate a file so age-gated sweeps consider it evictable.
  defp age(path, seconds) do
    t = System.system_time(:second) - seconds
    File.touch!(path, t)
  end

  setup do
    sid = "osa_taskout_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(Path.dirname(tasks_dir(sid))) end)
    {:ok, sid: sid}
  end

  describe "delete/2 (task retirement)" do
    test "removes the file and prunes the emptied dirs", %{sid: sid} do
      TaskOutput.ensure(sid, "t1")
      TaskOutput.append(sid, "t1", "hello")
      assert File.exists?(TaskOutput.path(sid, "t1"))

      assert :ok = TaskOutput.delete(sid, "t1")
      refute File.exists?(TaskOutput.path(sid, "t1"))
      refute File.exists?(tasks_dir(sid))
    end

    test "is a no-op without a session and never raises on a missing file", %{sid: sid} do
      assert :ok = TaskOutput.delete(nil, "t1")
      assert :ok = TaskOutput.delete(sid, "never-existed")
    end

    test "leaves a sibling task's file alone", %{sid: sid} do
      TaskOutput.ensure(sid, "keep")
      TaskOutput.ensure(sid, "drop")

      TaskOutput.delete(sid, "drop")
      assert File.exists?(TaskOutput.path(sid, "keep"))
      refute File.exists?(TaskOutput.path(sid, "drop"))
    end
  end

  describe "sweep_session/2 — the per-session count bound" do
    test "driving 200 tasks past a cap of 10 keeps the file count bounded", %{sid: sid} do
      # Simulates 200 sequential background tasks, each of which sweeps on start
      # exactly as BackgroundTask.init does. Everything is backdated so it is
      # eligible for eviction; the point is that the count never runs away.
      Enum.each(1..200, fn i ->
        TaskOutput.sweep_session(sid, max_files: 10, min_age_ms: 0)
        TaskOutput.ensure(sid, "task-#{i}")
        TaskOutput.append(sid, "task-#{i}", "chunk #{i}")
        age(TaskOutput.path(sid, "task-#{i}"), 300 + (200 - i))
      end)

      count = out_count(sid)

      assert count <= 11,
             "per-session output files must stay bounded by the cap, got #{count}"

      # And the survivors are the NEWEST tasks — eviction is oldest-first, so a
      # user can still read a recent one.
      assert File.exists?(TaskOutput.path(sid, "task-200"))
      refute File.exists?(TaskOutput.path(sid, "task-1"))
    end

    test "never evicts a file younger than the eviction floor", %{sid: sid} do
      Enum.each(1..30, fn i -> TaskOutput.ensure(sid, "fresh-#{i}") end)

      # Cap of 5, but every file is brand new: a live writer must not have its
      # output pulled out from under it.
      assert TaskOutput.sweep_session(sid, max_files: 5, min_age_ms: 60_000) == 0
      assert out_count(sid) == 30
    end

    test "evicts only the aged surplus, keeping fresh files", %{sid: sid} do
      Enum.each(1..10, fn i ->
        TaskOutput.ensure(sid, "old-#{i}")
        age(TaskOutput.path(sid, "old-#{i}"), 3600 + i)
      end)

      Enum.each(1..3, fn i -> TaskOutput.ensure(sid, "live-#{i}") end)

      TaskOutput.sweep_session(sid, max_files: 5, min_age_ms: 60_000)

      assert out_count(sid) == 5
      Enum.each(1..3, fn i -> assert File.exists?(TaskOutput.path(sid, "live-#{i}")) end)
    end

    test "under the cap it removes nothing", %{sid: sid} do
      Enum.each(1..4, fn i ->
        TaskOutput.ensure(sid, "t#{i}")
        age(TaskOutput.path(sid, "t#{i}"), 9999)
      end)

      assert TaskOutput.sweep_session(sid, max_files: 10, min_age_ms: 0) == 0
      assert out_count(sid) == 4
    end

    test "no session id means nothing to sweep" do
      assert TaskOutput.sweep_session(nil) == 0
    end
  end

  describe "sweep_orphans/1 — the boot sweep" do
    setup do
      root = Path.join(System.tmp_dir!(), "osa_orphan_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root}
    end

    defp seed(root, session, task, age_secs) do
      dir = Path.join([root, session, "tasks"])
      File.mkdir_p!(dir)
      p = Path.join(dir, task <> ".out")
      File.write!(p, "old output")
      File.touch!(p, System.system_time(:second) - age_secs)
      p
    end

    test "removes stale files across every session dir and prunes them", %{root: root} do
      a = seed(root, "sess-a", "t1", 7200)
      b = seed(root, "sess-a", "t2", 7200)
      c = seed(root, "sess-b", "t1", 7200)

      assert {:ok, 3} = TaskOutput.sweep_orphans(root: root, older_than_ms: 3_600_000)

      refute File.exists?(a)
      refute File.exists?(b)
      refute File.exists?(c)
      refute File.exists?(Path.join([root, "sess-a", "tasks"]))
    end

    test "spares files inside the retention window (a concurrent daemon's live output)", %{
      root: root
    } do
      stale = seed(root, "dead", "t1", 7200)
      live = seed(root, "other-daemon", "t1", 5)

      assert {:ok, 1} = TaskOutput.sweep_orphans(root: root, older_than_ms: 3_600_000)

      refute File.exists?(stale)
      assert File.exists?(live), "a second instance's fresh output must survive the boot sweep"
    end

    test "a missing root is not an error" do
      assert {:ok, 0} =
               TaskOutput.sweep_orphans(
                 root: Path.join(System.tmp_dir!(), "osa_no_such_root_xyz")
               )
    end

    test "ignores non-.out files", %{root: root} do
      dir = Path.join([root, "s", "tasks"])
      File.mkdir_p!(dir)
      keep = Path.join(dir, "notes.txt")
      File.write!(keep, "x")
      File.touch!(keep, System.system_time(:second) - 99_999)

      assert {:ok, 0} = TaskOutput.sweep_orphans(root: root, older_than_ms: 1000)
      assert File.exists?(keep)
    end
  end
end
