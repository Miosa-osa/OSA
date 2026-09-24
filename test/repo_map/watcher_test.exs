defmodule OptimalSystemAgent.RepoMap.WatcherTest do
  @moduledoc """
  The background half of "update it from tool results AND a file watcher" —
  polls on its own timer, diffing `git status` rather than rewalking, and
  only for roots someone has actually consulted.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.RepoMap
  alias OptimalSystemAgent.RepoMap.Watcher

  defp git!(dir, args) do
    System.cmd("git", args,
      cd: dir,
      env: [
        {"GIT_AUTHOR_NAME", "Test"},
        {"GIT_AUTHOR_EMAIL", "test@example.com"},
        {"GIT_COMMITTER_NAME", "Test"},
        {"GIT_COMMITTER_EMAIL", "test@example.com"}
      ]
    )
  end

  defp tmp_repo do
    dir =
      Path.join(System.tmp_dir!(), "repo-map-watcher-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "hello\n")
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "first"])
    dir
  end

  setup do
    # config/test.exs disables the app-supervised singleton (same reasoning
    # as `settings_watcher_enabled`) — re-enable it explicitly around this
    # module's own supervised instance, mirroring `Settings.Watcher`'s test
    # convention.
    Application.put_env(:optimal_system_agent, :repo_map_watcher_enabled, true)
    {:ok, pid} = Watcher.start_link(poll_ms: 60_000, roots: [])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Application.put_env(:optimal_system_agent, :repo_map_watcher_enabled, false)
    end)

    {:ok, pid: pid}
  end

  describe "register_root/1 and watching/0" do
    test "starts with no roots" do
      assert Watcher.watching() == []
    end

    test "adds and removes a root" do
      dir = tmp_repo()
      on_exit(fn -> File.rm_rf(dir) end)

      Watcher.register_root(dir)
      assert Path.expand(dir) in Watcher.watching()

      Watcher.unregister_root(dir)
      refute Path.expand(dir) in Watcher.watching()
    end

    test "registering the same root twice is idempotent" do
      dir = tmp_repo()
      on_exit(fn -> File.rm_rf(dir) end)

      Watcher.register_root(dir)
      Watcher.register_root(dir)
      assert Enum.count(Watcher.watching(), &(&1 == Path.expand(dir))) == 1
    end
  end

  describe "poll_now/0 — the tick" do
    test "does nothing for a registered root nobody has consulted via RepoMap.get/2" do
      dir = tmp_repo()
      on_exit(fn -> File.rm_rf(dir) end)

      Watcher.register_root(dir)
      refute RepoMap.cached?(dir)

      Watcher.poll_now()

      # Still uncached — the watcher must not be the thing that builds the
      # FIRST model for a root; that is `RepoMap.get/2`'s job.
      refute RepoMap.cached?(dir)
    end

    test "syncs git state for a root that HAS been consulted" do
      dir = tmp_repo()
      on_exit(fn -> File.rm_rf(dir) end)

      _model = RepoMap.get(dir)
      Watcher.register_root(dir)

      File.write!(Path.join(dir, "a.txt"), "changed\n")

      Watcher.poll_now()

      assert RepoMap.git_state(dir).dirty_count == 1
    end

    test "an unregistered root is never touched" do
      dir = tmp_repo()
      on_exit(fn -> File.rm_rf(dir) end)

      model1 = RepoMap.get(dir)
      File.write!(Path.join(dir, "a.txt"), "changed\n")

      # Deliberately NOT registered.
      Watcher.poll_now()

      model2 = RepoMap.get(dir)
      assert model2.updated_at == model1.updated_at
    end
  end

  describe "disabled via config" do
    test "init returns :ignore, so no process starts" do
      Application.put_env(:optimal_system_agent, :repo_map_watcher_enabled, false)

      on_exit(fn ->
        Application.delete_env(:optimal_system_agent, :repo_map_watcher_enabled)
      end)

      assert :ignore == Watcher.init([])
    end
  end
end
