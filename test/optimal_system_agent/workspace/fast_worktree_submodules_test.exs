defmodule OptimalSystemAgent.Workspace.FastWorktreeSubmodulesTest do
  @moduledoc """
  Real-fixture regression tests for the fast-worktree **data-loss** bug.

  `git ls-files` reports a submodule and an embedded independent repository as a
  single bare gitlink entry. A worktree populated from that list is created,
  reported as successful, and silently missing whole components. These tests do
  not mock git — the whole point is that git's real behavior is the surprise, so
  a mock would encode the assumption we are trying to falsify.

  The fixture mirrors `test/workspace/topology_test.exs`: a real `git init`
  parent, a real `git submodule add`, a real embedded repo with its own `.git`,
  plus gitignored and `node_modules` noise that must stay out.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias OptimalSystemAgent.Workspace.FastWorktree
  alias OptimalSystemAgent.Workspace.FastWorktree.Populate

  setup %{tmp_dir: tmp} do
    wt_dir = Path.join(tmp, "worktrees")
    prev = Application.get_env(:optimal_system_agent, :worktrees_dir)
    Application.put_env(:optimal_system_agent, :worktrees_dir, wt_dir)

    repo = build_constellation(Path.join(tmp, "repo"))

    on_exit(fn ->
      _ = FastWorktree.sweep(stale_only: false, repo_dir: repo)

      if prev,
        do: Application.put_env(:optimal_system_agent, :worktrees_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :worktrees_dir)
    end)

    {:ok, repo: repo, tmp: tmp}
  end

  # ── (a) Pin git's behavior first ───────────────────────────────────────
  #
  # If git ever starts listing these subtrees, these tests fail LOUDLY and tell
  # us the fix is no longer necessary — instead of the fix quietly becoming
  # dead code while everyone assumes it is still load-bearing.

  describe "git's own enumeration (the bug being fixed)" do
    test "ls-files collapses the submodule and both embedded repos", %{repo: repo} do
      {out, 0} = git(["ls-files"], repo)
      listed = String.split(out, "\n", trim: true)

      assert "vendor/subm" in listed
      assert "nested-repo" in listed

      refute Enum.any?(listed, &String.starts_with?(&1, "vendor/subm/"))
      refute Enum.any?(listed, &String.starts_with?(&1, "nested-repo/"))

      # …while the files unquestionably exist on disk.
      assert File.regular?(Path.join(repo, "vendor/subm/go.mod"))
      assert File.regular?(Path.join(repo, "nested-repo/deep/d.txt"))
    end

    test "an untracked embedded repo is emitted as a bare `dir/`, never its files", %{repo: repo} do
      {out, 0} = git(["ls-files", "--others", "--exclude-standard"], repo)
      listed = String.split(out, "\n", trim: true)

      assert "untracked-nested/" in listed
      refute Enum.any?(listed, &String.starts_with?(&1, "untracked-nested/u"))
    end

    test "--recurse-submodules covers the submodule but NOT the embedded repos", %{repo: repo} do
      {out, 0} = git(["ls-files", "--recurse-submodules"], repo)
      listed = String.split(out, "\n", trim: true)

      # This is why `--recurse-submodules` alone was not an acceptable fix.
      assert "vendor/subm/go.mod" in listed
      assert "nested-repo" in listed
      refute Enum.any?(listed, &String.starts_with?(&1, "nested-repo/"))
    end

    test "git status at the parent reports a DIRTY embedded repo as clean", %{repo: repo} do
      File.write!(Path.join(repo, "nested-repo/deep/d.txt"), "locally modified\n")
      {out, 0} = git(["status", "--porcelain"], repo)

      refute out =~ "nested-repo/deep/d.txt"
    end
  end

  # ── Enumeration ────────────────────────────────────────────────────────

  describe "Populate.working_tree_files/1" do
    test "includes every hidden subtree's files", %{repo: repo} do
      assert {:ok, files} = Populate.working_tree_files(repo)

      assert "vendor/subm/go.mod" in files
      assert "vendor/subm/cmd/subm/main.go" in files
      assert "nested-repo/n.txt" in files
      assert "nested-repo/deep/d.txt" in files
      assert "untracked-nested/u.txt" in files

      # …and still the ordinary ones.
      assert "README.md" in files
      assert "plaindir/p.txt" in files
    end

    test "still honours .gitignore, node_modules and build dirs", %{repo: repo} do
      assert {:ok, files} = Populate.working_tree_files(repo)

      refute Enum.any?(files, &String.contains?(&1, "node_modules"))
      refute Enum.any?(files, &String.starts_with?(&1, "generated/"))
      refute Enum.any?(files, &String.ends_with?(&1, ".log"))

      # A subtree's OWN .gitignore governs its contents — the parent's does not
      # reach inside it.
      refute "nested-repo/nested-ignored/x.txt" in files
      refute Enum.any?(files, &String.contains?(&1, "vendor/subm/target/"))
    end

    test "never emits a .git path", %{repo: repo} do
      assert {:ok, files} = Populate.working_tree_files(repo)

      refute Enum.any?(files, &(&1 == ".git" or String.contains?(&1, "/.git/")))
      refute Enum.any?(files, &String.starts_with?(&1, ".git/"))
    end

    test "hidden_subtree_files/1 returns only what a plain checkout would miss", %{repo: repo} do
      assert {:ok, hidden} = Populate.hidden_subtree_files(repo)

      assert "vendor/subm/go.mod" in hidden
      assert "nested-repo/n.txt" in hidden
      refute "README.md" in hidden
      refute "plaindir/p.txt" in hidden
    end

    test "an uninitialized submodule is empty, not an error", %{tmp: tmp} do
      repo = Path.join(tmp, "uninit")
      sub = Path.join(tmp, "uninit_src")

      init_repo(sub)
      write(sub, "s.txt", "s\n")
      commit_all(sub, "s")

      init_repo(repo)
      write(repo, "README.md", "r\n")
      commit_all(repo, "r")

      {_, 0} =
        git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "sub"], repo)

      commit_all(repo, "add sub")

      # Emulate a fresh clone: the gitlink and its empty placeholder dir remain.
      File.rm_rf!(Path.join(repo, "sub"))
      File.mkdir_p!(Path.join(repo, "sub"))

      assert {:ok, files} = Populate.working_tree_files(repo)
      assert "README.md" in files
      refute Enum.any?(files, &String.starts_with?(&1, "sub/"))
    end
  end

  # ── (b)+(c) The populated worktree ─────────────────────────────────────

  describe "create/2 with the :copy tier" do
    test "the worktree CONTAINS the submodule's and embedded repos' files", %{repo: repo} do
      assert {:ok, %{path: path, tier: :copy}} =
               FastWorktree.create("submtest", repo_dir: repo, prefer: [:copy])

      assert File.regular?(Path.join(path, "vendor/subm/go.mod"))
      assert File.regular?(Path.join(path, "vendor/subm/cmd/subm/main.go"))
      assert File.regular?(Path.join(path, "nested-repo/n.txt"))
      assert File.regular?(Path.join(path, "nested-repo/deep/d.txt"))
      assert File.regular?(Path.join(path, "untracked-nested/u.txt"))

      assert File.read!(Path.join(path, "vendor/subm/go.mod")) ==
               File.read!(Path.join(repo, "vendor/subm/go.mod"))

      assert File.regular?(Path.join(path, "README.md"))
    end

    test "the worktree does NOT contain ignored or node_modules files", %{repo: repo} do
      assert {:ok, %{path: path}} =
               FastWorktree.create("submclean", repo_dir: repo, prefer: [:copy])

      refute File.exists?(Path.join(path, "node_modules"))
      refute File.exists?(Path.join(path, "generated"))
      refute File.exists?(Path.join(path, "debug.log"))
      refute File.exists?(Path.join(path, "nested-repo/node_modules"))
      refute File.exists?(Path.join(path, "nested-repo/nested-ignored"))
      refute File.exists?(Path.join(path, "vendor/subm/target"))
    end

    test "uncommitted edits inside a submodule are mirrored, not the HEAD blob", %{repo: repo} do
      File.write!(Path.join(repo, "vendor/subm/go.mod"), "module example.com/DIRTY\n")

      assert {:ok, %{path: path}} =
               FastWorktree.create("submdirty", repo_dir: repo, prefer: [:copy])

      assert File.read!(Path.join(path, "vendor/subm/go.mod")) =~ "DIRTY"
    end

    test "the :git fallback tier also fills the subtrees a checkout leaves empty", %{repo: repo} do
      assert {:ok, %{path: path, tier: :git}} =
               FastWorktree.create("submgit", repo_dir: repo, prefer: [:git])

      # A plain `git worktree add` leaves these as empty directories.
      assert File.regular?(Path.join(path, "vendor/subm/go.mod"))
      assert File.regular?(Path.join(path, "nested-repo/deep/d.txt"))
      refute File.exists?(Path.join(path, "node_modules"))
    end
  end

  # ── (d) Partial population must be loud ────────────────────────────────

  describe "enumeration failure" do
    test "an unenumerable subtree is an error, never a quiet success", %{tmp: tmp} do
      repo = build_too_deep(Path.join(tmp, "deep"))

      assert {:error, {:incomplete_enumeration, [{path, kind, _reason} | _]}} =
               Populate.working_tree_files(repo)

      assert is_binary(path)
      assert kind == :too_deep
    end

    test "create/2 ABORTS instead of falling through to a tier that hides it", %{tmp: tmp} do
      repo = build_too_deep(Path.join(tmp, "deep2"))

      assert {:error, reason} = FastWorktree.create("deepfail", repo_dir: repo, prefer: [:copy])
      assert reason =~ "incomplete_enumeration"

      # And it left nothing behind that could be mistaken for a good worktree.
      refute File.dir?(Path.join(Path.join(tmp, "worktrees"), "deepfail"))
    end

    test "fatal?/1 distinguishes an enumeration failure from a tier failure" do
      assert Populate.fatal?({:incomplete_enumeration, []})
      refute Populate.fatal?({:copy_failed, :copy, 1, :enoent})
      refute Populate.fatal?({:git, 128, "not a repository"})
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # root/                        git repo
  #   README.md, plaindir/p.txt
  #   .gitignore -> generated/, node_modules/, *.log
  #   generated/g.txt            ignored
  #   node_modules/junk/a.js     ignored
  #   debug.log                  ignored
  #   nested-repo/               EMBEDDED INDEPENDENT REPO, committed as gitlink
  #     n.txt, deep/d.txt
  #     nested-ignored/x.txt     ignored by the NESTED repo's own .gitignore
  #     node_modules/n/b.js      ignored
  #   vendor/subm                REAL SUBMODULE (git submodule add)
  #     go.mod, cmd/subm/main.go
  #     target/junk              ignored by the SUBMODULE's own .gitignore
  #   untracked-nested/          EMBEDDED REPO, never committed
  #     u.txt
  defp build_constellation(root) do
    subsrc = root <> "_subsrc"
    on_exit(fn -> File.rm_rf(subsrc) end)

    init_repo(subsrc)
    write(subsrc, ".gitignore", "target/\n")
    write(subsrc, "go.mod", "module example.com/subm\n\ngo 1.22\n")
    write(subsrc, "cmd/subm/main.go", "package main\n\nfunc main() {}\n")
    write(subsrc, "target/junk", "build output\n")
    commit_all(subsrc, "subm")

    init_repo(root)
    write(root, ".gitignore", "generated/\nnode_modules/\n*.log\n")
    write(root, "README.md", "constellation\n")
    write(root, "plaindir/p.txt", "plain\n")
    write(root, "generated/g.txt", "generated\n")
    write(root, "node_modules/junk/a.js", "junk\n")
    write(root, "debug.log", "noise\n")
    commit_all(root, "root")

    nested = Path.join(root, "nested-repo")
    init_repo(nested)
    write(nested, ".gitignore", "nested-ignored/\nnode_modules/\n")
    write(nested, "n.txt", "nested\n")
    write(nested, "deep/d.txt", "deep\n")
    write(nested, "nested-ignored/x.txt", "hidden\n")
    write(nested, "node_modules/n/b.js", "junk\n")
    commit_all(nested, "nested")

    # `git add -A` records the embedded repo as a bare gitlink — with a warning
    # on stderr, which is exactly the situation this test exists for.
    commit_all(root, "embed nested repo")

    {_, 0} =
      git(
        ["-c", "protocol.file.allow=always", "submodule", "add", "-q", subsrc, "vendor/subm"],
        root
      )

    commit_all(root, "add submodule")

    untracked = Path.join(root, "untracked-nested")
    init_repo(untracked)
    write(untracked, "u.txt", "untracked repo\n")
    commit_all(untracked, "u")

    root
  end

  # A chain of embedded repos deeper than the recursion bound: enumeration
  # cannot complete, so it must report rather than truncate.
  defp build_too_deep(root) do
    init_repo(root)
    write(root, "README.md", "top\n")

    dirs =
      Enum.reduce(1..10, [root], fn i, [parent | _] = acc ->
        child = Path.join(parent, "l#{i}")
        init_repo(child)
        write(child, "f#{i}.txt", "level #{i}\n")
        [child | acc]
      end)

    # Commit innermost-outward so every level records its child as a gitlink.
    Enum.each(dirs, &commit_all(&1, "level"))
    root
  end

  defp write(root, rel, body) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp init_repo(dir) do
    File.mkdir_p!(dir)
    {_, 0} = git(["-c", "init.defaultBranch=main", "init", "-q", "."], dir)
    dir
  end

  defp commit_all(dir, msg) do
    {_, 0} = git(["add", "-A"], dir)
    {_, _} = git(["commit", "-q", "--no-verify", "-m", msg], dir)
    dir
  end

  defp git(args, cwd),
    do: System.cmd("git", args, cd: cwd, stderr_to_stdout: true, env: git_env())

  # Isolate from the developer's own git config (hooks, templates, signing).
  defp git_env do
    [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      {"GIT_AUTHOR_NAME", "osa-test"},
      {"GIT_AUTHOR_EMAIL", "osa@test.invalid"},
      {"GIT_COMMITTER_NAME", "osa-test"},
      {"GIT_COMMITTER_EMAIL", "osa@test.invalid"}
    ]
  end
end
