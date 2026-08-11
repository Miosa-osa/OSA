defmodule OptimalSystemAgent.Settings.WatcherCoverageTest do
  @moduledoc """
  Two gaps in the settings watcher.

  1. It is a singleton polling exactly ONE root — the process-global
     `Workspace.Cwd`, via `Settings.source_paths/0`. OSA routinely runs under
     other roots (`Agent.Fleet`'s `:working_dir`, the orchestrator's
     `repo_dir`, `Workspace.FastWorktree` worktrees), and `.osa/settings.json`
     under those was never polled and never reported.

  2. Its change signature was `{mtime, size}`, which never looks at content.
     `File.stat` mtime has 1-second POSIX granularity and the poll interval is
     also 1s, so a same-size rewrite inside the same second was missed
     entirely. Because `fire/1` calls `Settings.apply_env_settings/0`, a missed
     reload leaves stale `env` vars in the real OS environment.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Settings.Watcher

  setup do
    prev = Application.get_env(:optimal_system_agent, :settings_watcher_enabled)
    Application.put_env(:optimal_system_agent, :settings_watcher_enabled, true)

    root = Path.join(System.tmp_dir!(), "osa-watch-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".osa"))

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(prev) do
        Application.delete_env(:optimal_system_agent, :settings_watcher_enabled)
      else
        Application.put_env(:optimal_system_agent, :settings_watcher_enabled, prev)
      end
    end)

    {:ok, root: root, project: Path.join(root, ".osa/settings.json")}
  end

  describe "the watch set can cover more than the process-global cwd" do
    test "a registered root's settings files are polled", %{root: root, project: project} do
      File.write!(project, ~s({"a": 1}))
      start_supervised!({Watcher, poll_ms: 30})

      refute Watcher.watching?(project),
             "an unregistered alternate root should not be watched yet"

      :ok = Watcher.register_root(root)
      # Let the cast land.
      _ = Watcher.watching()

      assert Watcher.watching?(project),
             "a registered root's settings.json must be in the watch set"

      assert Watcher.watching?(Path.join(root, ".osa/settings.local.json"))
    end

    test "registering is idempotent", %{root: root} do
      start_supervised!({Watcher, poll_ms: 30})
      :ok = Watcher.register_root(root)
      :ok = Watcher.register_root(root)

      watched = Watcher.watching()
      assert length(watched) == length(Enum.uniq(watched))
    end

    test "unregistering removes the paths again", %{root: root, project: project} do
      start_supervised!({Watcher, poll_ms: 30})
      :ok = Watcher.register_root(root)
      assert Watcher.watching?(project)

      :ok = Watcher.unregister_root(root)
      refute Watcher.watching?(project)
    end

    test "roots can be supplied at start", %{root: root, project: project} do
      start_supervised!({Watcher, poll_ms: 30, roots: [root]})
      assert Watcher.watching?(project)
    end

    test "the cwd cascade is still watched", %{root: root} do
      start_supervised!({Watcher, poll_ms: 30})
      :ok = Watcher.register_root(root)

      cwd_project = Path.join(OptimalSystemAgent.Workspace.Cwd.get(), ".osa/settings.json")
      assert Watcher.watching?(cwd_project)
    end

    test "a bad root argument is ignored rather than crashing the watcher" do
      start_supervised!({Watcher, poll_ms: 30})
      assert :ok = Watcher.register_root(nil)
      assert :ok = Watcher.register_root("")
      assert :ok = Watcher.unregister_root(nil)
      assert is_list(Watcher.watching())
    end
  end

  describe "a same-size rewrite in the same second is detected" do
    test "an edit that changes content but not size or mtime fires a reload", %{
      root: root,
      project: project
    } do
      File.write!(project, ~s({"osa_watch_probe":"aaaa"}))
      stat = File.stat!(project, time: :posix)

      :ok = Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "command_center:events")
      start_supervised!({Watcher, poll_ms: 30, roots: [root]})

      # Drain anything the initial polls produce for unrelated cwd files.
      receive do
        {:command_center_event, %{type: "settings_changed"}} -> :ok
      after
        200 -> :ok
      end

      # Byte-for-byte the same LENGTH, and forced to the same mtime and size —
      # exactly what a one-character edit inside the poll window looks like.
      File.write!(project, ~s({"osa_watch_probe":"bbbb"}))
      File.touch!(project, stat.mtime)

      after_stat = File.stat!(project, time: :posix)
      assert after_stat.size == stat.size, "fixture must keep the size identical"
      assert after_stat.mtime == stat.mtime, "fixture must keep the mtime identical"

      assert_receive {:command_center_event, %{type: "settings_changed"}}, 3_000
    end
  end

  describe "signature computation fails open" do
    test "a settings file that cannot be read does not silently suppress reloads", %{
      root: root,
      project: project
    } do
      File.write!(project, ~s({"a":1}))
      File.chmod!(project, 0o000)
      on_exit(fn -> File.chmod(project, 0o644) end)

      # The watcher must still start and still report the path as covered
      # rather than dropping it from the set.
      start_supervised!({Watcher, poll_ms: 30, roots: [root]})
      assert Watcher.watching?(project)
    end
  end
end
