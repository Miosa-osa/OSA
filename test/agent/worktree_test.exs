defmodule OptimalSystemAgent.Agent.WorktreeTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Worktree

  test "cleanup preserves changed worktree unless discard or merge is explicit" do
    repo = tmp_repo!()
    agent_id = "test-preserve-#{System.unique_integer([:positive])}"

    assert {:ok, info} = Worktree.create(agent_id, repo_dir: repo)

    on_exit(fn ->
      Worktree.cleanup(info.path, repo_dir: repo, discard: true)
      File.rm_rf(repo)
    end)

    File.write!(Path.join(info.path, "changed.txt"), "changed")

    assert :ok = Worktree.cleanup(info.path, repo_dir: repo)
    assert File.dir?(info.path)

    assert :ok = Worktree.cleanup(info.path, repo_dir: repo, discard: true)
    refute File.exists?(info.path)
  end

  defp tmp_repo! do
    repo = Path.join(System.tmp_dir!(), "osa_worktree_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    {_out, 0} = System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo)
    {_out, 0} = System.cmd("git", ["config", "user.name", "OSA Test"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "test")
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: repo, stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["commit", "-m", "initial"], cd: repo, stderr_to_stdout: true)

    repo
  end
end
