defmodule OptimalSystemAgent.Workspace.FastWorktreeTest do
  @moduledoc """
  Tests for the fast CoW worktree isolation feature.

  On the CI/dev box (ext4, no reflink/btrfs) the `:copy` tier is exercised for
  real. Capability-gated tiers (btrfs/reflink) are covered via the fall-through
  behavior and the explicit `:prefer` override.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias OptimalSystemAgent.Workspace.FastWorktree
  alias OptimalSystemAgent.Workspace.FastWorktree.{Capabilities, Metadata}

  setup %{tmp_dir: tmp} do
    # Keep worktrees + sidecars entirely inside the test's tmp_dir.
    wt_dir = Path.join(tmp, "worktrees")
    prev = Application.get_env(:optimal_system_agent, :worktrees_dir)
    Application.put_env(:optimal_system_agent, :worktrees_dir, wt_dir)

    repo = Path.join(tmp, "repo")
    init_git_repo(repo)

    on_exit(fn ->
      # Best-effort reclaim of anything the test created, then restore config.
      _ = FastWorktree.sweep(stale_only: false, repo_dir: repo)

      if prev,
        do: Application.put_env(:optimal_system_agent, :worktrees_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :worktrees_dir)
    end)

    {:ok, repo: repo, wt_dir: wt_dir}
  end

  # ── capability detection ───────────────────────────────────────────────

  describe "capabilities/1" do
    test "returns a sane, well-shaped result for the repo filesystem", %{repo: repo} do
      Capabilities.clear_cache()
      caps = FastWorktree.capabilities(repo)

      assert is_map(caps)
      assert is_boolean(caps.reflink)
      assert is_boolean(caps.btrfs)
      assert is_boolean(caps.overlayfs)
      assert is_binary(caps.fs_type)
      # btrfs implies the fs actually reports btrfs.
      if caps.btrfs, do: assert(caps.fs_type == "btrfs")
    end

    test "is cached per device (second call returns identical map)", %{repo: repo} do
      Capabilities.clear_cache()
      a = FastWorktree.capabilities(repo)
      b = FastWorktree.capabilities(repo)
      assert a == b
      assert a.probed_at == b.probed_at
    end
  end

  # ── worktree creation ──────────────────────────────────────────────────

  describe "create/2" do
    test "yields a real git worktree containing the repo contents", %{repo: repo} do
      assert {:ok, info} = FastWorktree.create("agent-create", repo_dir: repo)

      assert File.dir?(info.path)
      # It is a registered git worktree.
      assert {out, 0} = System.cmd("git", ["worktree", "list"], cd: repo)
      assert String.contains?(out, info.path)
      # Repo contents are present.
      assert File.read!(Path.join(info.path, "README.md")) =~ "hello"
      assert File.read!(Path.join(info.path, "lib/mod.txt")) =~ "module"
      # On ext4 this is the copy tier; whatever it is, it must be one of the ladder.
      assert info.tier in [:btrfs, :reflink, :copy, :git]
      # Branch was created.
      assert {branch_out, 0} = System.cmd("git", ["branch", "--list", info.branch], cd: repo)
      assert String.trim(branch_out) != ""

      FastWorktree.teardown(info.path, repo_dir: repo)
    end

    test "copy tier mirrors the source's dirty (uncommitted) working-tree state", %{repo: repo} do
      # Dirty a tracked file + add an untracked (non-ignored) file in the source.
      File.write!(Path.join(repo, "README.md"), "hello DIRTY EDIT\n")
      File.write!(Path.join(repo, "new_untracked.txt"), "fresh\n")

      assert {:ok, info} = FastWorktree.create("agent-dirty", repo_dir: repo, prefer: [:copy])
      assert info.tier == :copy

      # The worktree sees the uncommitted edit and the untracked file.
      assert File.read!(Path.join(info.path, "README.md")) =~ "DIRTY EDIT"
      assert File.exists?(Path.join(info.path, "new_untracked.txt"))

      # And `git status` in the worktree reports the same dirty state.
      assert {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: info.path)
      assert status =~ "README.md"
      assert status =~ "new_untracked.txt"

      FastWorktree.teardown(info.path, discard: true, repo_dir: repo)
    end

    test "git-ignored files are NOT copied into the worktree", %{repo: repo} do
      File.write!(Path.join(repo, "secret.log"), "should be ignored\n")

      assert {:ok, info} = FastWorktree.create("agent-ignore", repo_dir: repo, prefer: [:copy])
      refute File.exists?(Path.join(info.path, "secret.log"))

      FastWorktree.teardown(info.path, discard: true, repo_dir: repo)
    end

    test "prefer: [:git] uses the plain-checkout fallback tier", %{repo: repo} do
      assert {:ok, info} = FastWorktree.create("agent-git", repo_dir: repo, prefer: [:git])
      assert info.tier == :git
      assert File.read!(Path.join(info.path, "README.md")) =~ "hello"

      FastWorktree.teardown(info.path, repo_dir: repo)
    end

    test "writes a crash-recovery sidecar for the worktree", %{repo: repo, wt_dir: wt_dir} do
      assert {:ok, _info} = FastWorktree.create("agent-sidecar", repo_dir: repo)

      records = Metadata.list(wt_dir)
      assert Enum.any?(records, &(&1["id"] == "agent-sidecar"))
      rec = Enum.find(records, &(&1["id"] == "agent-sidecar"))
      assert rec["branch"]
      assert rec["repo_dir"] == repo
      assert rec["boot_token"] == Metadata.boot_token()

      FastWorktree.teardown(Path.join(wt_dir, "agent-sidecar"), repo_dir: repo)
    end

    test "errors cleanly when the source is not a git repo" do
      # Must live OUTSIDE any git repo — the project's own tmp_dir is inside
      # OSA's repo, so use a fresh dir under the system temp root.
      non_repo = Path.join(System.tmp_dir!(), "osa_nonrepo_#{System.unique_integer([:positive])}")
      File.mkdir_p!(non_repo)
      on_exit(fn -> File.rm_rf(non_repo) end)

      assert {:error, msg} = FastWorktree.create("agent-nonrepo", repo_dir: non_repo)
      assert msg =~ "not inside a git repository"
    end

    test "falls through to the next tier when a tier reports failure", %{repo: repo} do
      # A bogus tier is :unsupported → must fall through to :copy and succeed.
      assert {:ok, info} = FastWorktree.create("agent-fallthrough", repo_dir: repo, prefer: [:bogus])
      assert info.tier in [:copy, :git]
      FastWorktree.teardown(info.path, repo_dir: repo)
    end
  end

  # ── teardown ───────────────────────────────────────────────────────────

  describe "teardown/2" do
    test "removes a clean worktree, its git registration, and its sidecar",
         %{repo: repo, wt_dir: wt_dir} do
      {:ok, info} = FastWorktree.create("agent-teardown", repo_dir: repo)
      assert File.dir?(info.path)

      assert :ok = FastWorktree.teardown(info.path, repo_dir: repo)

      refute File.dir?(info.path)
      # Deregistered from git.
      assert {out, 0} = System.cmd("git", ["worktree", "list"], cd: repo)
      refute String.contains?(out, info.path)
      # Sidecar gone.
      refute Enum.any?(Metadata.list(wt_dir), &(&1["id"] == "agent-teardown"))
    end

    test "preserves a dirty worktree by default, discards it on discard: true",
         %{repo: repo} do
      {:ok, info} = FastWorktree.create("agent-dirty-teardown", repo_dir: repo)
      # Make the worktree dirty.
      File.write!(Path.join(info.path, "README.md"), "changed in worktree\n")

      # Default: dirty worktree is preserved.
      assert :ok = FastWorktree.teardown(info.path, repo_dir: repo)
      assert File.dir?(info.path)

      # discard: true removes it.
      assert :ok = FastWorktree.teardown(info.path, discard: true, repo_dir: repo)
      refute File.dir?(info.path)
    end
  end

  # ── crash-recovery sweep ───────────────────────────────────────────────

  describe "sweep/1" do
    test "reclaims a worktree from a previous (crashed) VM run", %{repo: repo, wt_dir: wt_dir} do
      {:ok, info} = FastWorktree.create("agent-crashed", repo_dir: repo)
      assert File.dir?(info.path)

      # Simulate a crash+restart by rewriting the sidecar's boot token to a
      # stale value, then sweeping.
      sidecar = Metadata.sidecar_path(wt_dir, "agent-crashed")
      rec = sidecar |> File.read!() |> Jason.decode!()
      File.write!(sidecar, Jason.encode!(Map.put(rec, "boot_token", "STALE-PREVIOUS-RUN")))

      assert {:ok, %{removed: removed}} = FastWorktree.sweep(repo_dir: repo)
      assert info.path in removed
      refute File.dir?(info.path)
      refute Enum.any?(Metadata.list(wt_dir), &(&1["id"] == "agent-crashed"))
    end

    test "keeps worktrees created by the current run (stale_only default)", %{repo: repo} do
      {:ok, info} = FastWorktree.create("agent-current", repo_dir: repo)

      assert {:ok, %{removed: removed, kept: kept}} = FastWorktree.sweep(repo_dir: repo)
      refute info.path in removed
      assert info.path in kept
      assert File.dir?(info.path)

      FastWorktree.teardown(info.path, repo_dir: repo)
    end

    test "reclaims a worktree whose directory vanished (dangling sidecar)",
         %{repo: repo, wt_dir: wt_dir} do
      {:ok, info} = FastWorktree.create("agent-vanished", repo_dir: repo)
      # Nuke the directory out from under git without deregistering.
      File.rm_rf!(info.path)

      assert {:ok, %{removed: removed}} = FastWorktree.sweep(repo_dir: repo)
      assert info.path in removed
      refute Enum.any?(Metadata.list(wt_dir), &(&1["id"] == "agent-vanished"))
    end

    test "stale_only: false reclaims everything (hard reset)", %{repo: repo} do
      {:ok, a} = FastWorktree.create("agent-a", repo_dir: repo)
      {:ok, b} = FastWorktree.create("agent-b", repo_dir: repo)

      assert {:ok, %{removed: removed}} = FastWorktree.sweep(stale_only: false, repo_dir: repo)
      assert a.path in removed
      assert b.path in removed
      refute File.dir?(a.path)
      refute File.dir?(b.path)
    end
  end

  # ── P8: durable-ref worktree snapshot ───────────────────────────────────

  describe "snapshot_ref/2" do
    test "creates a durable ref resolvable from the source repo, capturing dirty changes",
         %{repo: repo} do
      {:ok, info} = FastWorktree.create("agent-snap", repo_dir: repo)

      # Simulate a completed child's dirty (uncommitted) work.
      File.write!(Path.join(info.path, "README.md"), "snapshot me\n")
      File.write!(Path.join(info.path, "new_file.txt"), "child output\n")

      assert {:ok, ref} = FastWorktree.snapshot_ref(info.path, id: "agent-snap", repo_dir: repo)
      assert ref =~ "refs/osa/subagent-snapshots/agent-snap"

      # The ref resolves and shows the child's dirty state, from the SOURCE repo.
      assert {out, 0} = System.cmd("git", ["show", "#{ref}:README.md"], cd: repo)
      assert out =~ "snapshot me"
      assert {out2, 0} = System.cmd("git", ["show", "#{ref}:new_file.txt"], cd: repo)
      assert out2 =~ "child output"

      # Ref survives teardown discarding the worktree entirely — the whole
      # point of a durable ref vs. merge-or-discard.
      FastWorktree.teardown(info.path, discard: true, repo_dir: repo)
      refute File.dir?(info.path)
      assert {show_out, 0} = System.cmd("git", ["show", "#{ref}:README.md"], cd: repo)
      assert show_out =~ "snapshot me"
    end

    test "honors a custom ref_prefix", %{repo: repo} do
      {:ok, info} = FastWorktree.create("agent-snap-prefix", repo_dir: repo)

      assert {:ok, ref} =
               FastWorktree.snapshot_ref(info.path,
                 id: "agent-snap-prefix",
                 repo_dir: repo,
                 ref_prefix: "refs/osa/custom-namespace"
               )

      assert ref =~ "refs/osa/custom-namespace/agent-snap-prefix"

      FastWorktree.teardown(info.path, discard: true, repo_dir: repo)
    end

    test "errors cleanly when the worktree directory is missing", %{repo: repo} do
      assert {:error, :worktree_missing} =
               FastWorktree.snapshot_ref("/nonexistent/path/xyz", repo_dir: repo)
    end
  end

  # ── fixture ────────────────────────────────────────────────────────────

  defp init_git_repo(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "README.md"), "hello world\n")
    File.write!(Path.join(dir, "lib/mod.txt"), "module contents\n")
    File.write!(Path.join(dir, ".gitignore"), "*.log\n")

    run = fn args -> {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true) end
    run.(["init", "-q"])
    run.(["config", "user.email", "test@osa.local"])
    run.(["config", "user.name", "OSA Test"])
    run.(["config", "commit.gpgsign", "false"])
    run.(["add", "-A"])
    run.(["commit", "-q", "-m", "initial"])
    :ok
  end
end
