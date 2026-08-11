defmodule OptimalSystemAgent.Workspace.FastWorktreeReclaimTest do
  @moduledoc """
  Subagent worktrees must not be destroyed without a durable snapshot.

  A worktree path is DETERMINISTIC per subagent id, so a retry or a resume of
  the same id lands on the tree the previous run left behind. `create/2` used to
  `fast_remove` (rm -rf + `git worktree prune` + `git branch -D`) that tree
  unconditionally, taking its uncommitted work with it. And `sweep/1` treated
  "sidecar boot_token is from another VM" as licence to remove — including the
  dirty worktrees `teardown/2` deliberately preserves for review.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias OptimalSystemAgent.Workspace.FastWorktree
  alias OptimalSystemAgent.Workspace.FastWorktree.Metadata

  setup %{tmp_dir: tmp} do
    wt_dir = Path.join(tmp, "worktrees")
    prev = Application.get_env(:optimal_system_agent, :worktrees_dir)
    Application.put_env(:optimal_system_agent, :worktrees_dir, wt_dir)

    repo = Path.join(tmp, "repo")
    init_git_repo(repo)

    on_exit(fn ->
      _ = FastWorktree.sweep(stale_only: false, force: true, repo_dir: repo)

      if prev,
        do: Application.put_env(:optimal_system_agent, :worktrees_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :worktrees_dir)
    end)

    {:ok, repo: repo, wt_dir: wt_dir}
  end

  defp git!(args, cd), do: {_, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)

  defp init_git_repo(dir) do
    File.mkdir_p!(dir)
    git!(["init", "-q", "-b", "main"], dir)
    git!(["config", "user.email", "test@example.com"], dir)
    git!(["config", "user.name", "Test"], dir)
    File.write!(Path.join(dir, "README.md"), "seed\n")
    git!(["add", "-A"], dir)
    git!(["commit", "-q", "-m", "seed"], dir)
  end

  describe "create/2 reclaiming an existing worktree at the same id" do
    test "preserves the previous run's UNCOMMITTED work in a durable ref",
         %{repo: repo} do
      {:ok, first} = FastWorktree.create("agent-retry", repo_dir: repo)

      # The previous run's work: never committed, exists only in the worktree.
      File.write!(Path.join(first.path, "in_progress.txt"), "half-finished work\n")

      # A retry / resume of the SAME subagent id lands on the same path.
      {:ok, second} = FastWorktree.create("agent-retry", repo_dir: repo)
      assert second.path == first.path

      # The file is gone from the fresh tree — that part is expected.
      refute File.exists?(Path.join(second.path, "in_progress.txt"))

      # But it must still be recoverable from the snapshot namespace.
      {out, 0} =
        System.cmd("git", ["for-each-ref", "--format=%(refname)", "refs/osa/subagent-snapshots"],
          cd: repo,
          stderr_to_stdout: true
        )

      refs = out |> String.split("\n", trim: true)

      assert refs != [],
             "the dirty worktree was destroyed with no snapshot ref written — the work is gone"

      recovered =
        Enum.find_value(refs, fn ref ->
          case System.cmd("git", ["show", "#{ref}:in_progress.txt"],
                 cd: repo,
                 stderr_to_stdout: true
               ) do
            {content, 0} -> content
            _ -> nil
          end
        end)

      assert recovered == "half-finished work\n"
    end

    test "a CLEAN existing worktree is still reclaimed directly", %{repo: repo} do
      {:ok, first} = FastWorktree.create("agent-clean", repo_dir: repo)
      assert File.dir?(first.path)

      {:ok, second} = FastWorktree.create("agent-clean", repo_dir: repo)
      assert second.path == first.path
      assert File.dir?(second.path)
    end

    test "reclaim: :force skips the snapshot gate", %{repo: repo} do
      {:ok, first} = FastWorktree.create("agent-forced", repo_dir: repo)
      File.write!(Path.join(first.path, "scratch.txt"), "throwaway\n")

      assert {:ok, second} = FastWorktree.create("agent-forced", repo_dir: repo, reclaim: :force)
      assert second.path == first.path
    end
  end

  describe "sweep/1 dirty gate" do
    test "keeps an orphaned worktree that has uncommitted changes",
         %{repo: repo, wt_dir: wt_dir} do
      {:ok, info} = FastWorktree.create("agent-dirty-orphan", repo_dir: repo)
      File.write!(Path.join(info.path, "unsaved.txt"), "review me\n")

      # Make it look like it came from a previous (crashed) VM.
      sidecar = Metadata.sidecar_path(wt_dir, "agent-dirty-orphan")
      rec = sidecar |> File.read!() |> Jason.decode!()
      File.write!(sidecar, Jason.encode!(Map.put(rec, "boot_token", "STALE-PREVIOUS-RUN")))

      assert {:ok, %{removed: removed, kept: kept}} = FastWorktree.sweep(repo_dir: repo)

      refute info.path in removed,
             "sweep destroyed a dirty worktree — exactly what teardown/2 preserves for review"

      assert info.path in kept
      assert File.read!(Path.join(info.path, "unsaved.txt")) == "review me\n"
    end

    test "force: true still reclaims a dirty orphan", %{repo: repo, wt_dir: wt_dir} do
      {:ok, info} = FastWorktree.create("agent-force-sweep", repo_dir: repo)
      File.write!(Path.join(info.path, "unsaved.txt"), "gone\n")

      sidecar = Metadata.sidecar_path(wt_dir, "agent-force-sweep")
      rec = sidecar |> File.read!() |> Jason.decode!()
      File.write!(sidecar, Jason.encode!(Map.put(rec, "boot_token", "STALE-PREVIOUS-RUN")))

      assert {:ok, %{removed: removed}} = FastWorktree.sweep(repo_dir: repo, force: true)
      assert info.path in removed
      refute File.dir?(info.path)
    end

    test "a CLEAN orphan is still reclaimed by default", %{repo: repo, wt_dir: wt_dir} do
      {:ok, info} = FastWorktree.create("agent-clean-orphan", repo_dir: repo)

      sidecar = Metadata.sidecar_path(wt_dir, "agent-clean-orphan")
      rec = sidecar |> File.read!() |> Jason.decode!()
      File.write!(sidecar, Jason.encode!(Map.put(rec, "boot_token", "STALE-PREVIOUS-RUN")))

      assert {:ok, %{removed: removed}} = FastWorktree.sweep(repo_dir: repo)
      assert info.path in removed
      refute File.dir?(info.path)
    end
  end
end
