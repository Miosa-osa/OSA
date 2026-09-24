defmodule OptimalSystemAgent.RepoMap.GitStateTest do
  @moduledoc """
  A verifiable "which checkout is this" snapshot — the guard against
  quietly working against a stale clone.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.RepoMap.GitState

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", args,
        cd: dir,
        env: [
          {"GIT_AUTHOR_NAME", "Test"},
          {"GIT_AUTHOR_EMAIL", "test@example.com"},
          {"GIT_COMMITTER_NAME", "Test"},
          {"GIT_COMMITTER_EMAIL", "test@example.com"}
        ]
      )

    out
  end

  defp tmp_repo do
    dir = Path.join(System.tmp_dir!(), "repo-map-gitstate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "a.txt"), "hello\n")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "first"])
    dir
  end

  describe "refresh/1 — not a git repo" do
    test "a plain directory returns nil" do
      dir = Path.join(System.tmp_dir!(), "not-a-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert GitState.refresh(dir) == nil
    end
  end

  describe "refresh/1 — a clean repo" do
    setup do
      dir = tmp_repo()
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "reports the branch and a HEAD sha", %{dir: dir} do
      state = GitState.refresh(dir)
      assert state.branch == "main"
      assert is_binary(state.head_sha)
      assert byte_size(state.head_sha) == 40
      assert state.head_sha_short == String.slice(state.head_sha, 0, 8)
    end

    test "reports zero dirty files", %{dir: dir} do
      state = GitState.refresh(dir)
      assert state.dirty_count == 0
      assert state.dirty_files == []
    end

    test "no upstream means no ahead/behind" do
      dir = tmp_repo()
      on_exit(fn -> File.rm_rf(dir) end)
      state = GitState.refresh(dir)
      assert state.ahead == nil
      assert state.behind == nil
      assert state.upstream == nil
    end

    test "reports a last-commit timestamp", %{dir: dir} do
      state = GitState.refresh(dir)
      assert is_binary(state.last_commit_at)
      assert {:ok, _, _} = DateTime.from_iso8601(state.last_commit_at)
    end
  end

  describe "refresh/1 — a dirty repo" do
    test "an untracked and a modified file are both counted" do
      dir = tmp_repo()
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(Path.join(dir, "a.txt"), "changed\n")
      File.write!(Path.join(dir, "b.txt"), "new\n")

      state = GitState.refresh(dir)
      assert state.dirty_count == 2
      assert Enum.any?(state.dirty_files, &String.contains?(&1, "a.txt"))
      assert Enum.any?(state.dirty_files, &String.contains?(&1, "b.txt"))
    end
  end
end
