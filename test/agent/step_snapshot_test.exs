defmodule OptimalSystemAgent.Agent.StepSnapshotTest do
  @moduledoc """
  Filesystem step snapshots live in hidden refs `refs/osa-step/<session>/<n>`.
  They do not commit on the user's branch, do not push, and do not rewrite
  the conversation transcript (`updates.jsonl`).
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.StepSnapshot

  setup do
    root = init_repo()
    sid = "step-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, sid: sid}
  end

  test "record twice, revert 1 restores first tree", %{root: root, sid: sid} do
    path = Path.join(root, "file.txt")
    File.write!(path, "v1\n")

    assert {:ok, first} = StepSnapshot.record(sid, root)
    assert first.n == 1
    assert first.ref == "refs/osa-step/#{sid}/1"
    assert is_binary(first.commit) and first.commit != ""
    assert File.read!(path) == "v1\n"

    File.write!(path, "v2\n")
    assert {:ok, second} = StepSnapshot.record(sid, root)
    assert second.n == 2
    assert File.read!(path) == "v2\n"

    assert {:ok, result} = StepSnapshot.revert(sid, 1, cwd: root)
    assert result.restored_n == 1
    assert result.transcript_rewritten == false
    assert File.read!(path) == "v1\n"

    steps = StepSnapshot.list(sid)
    assert Enum.map(steps, & &1.n) == [1, 2]
  end

  test "missing git repo errors", %{sid: sid} do
    root = Path.join(System.tmp_dir!(), "osa-step-nogit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, reason} = StepSnapshot.record(sid, root)
    assert reason =~ "git"
  end

  test "missing git repo errors with injected git fn", %{root: root, sid: sid} do
    git_fn = fn cwd, args ->
      assert cwd == root
      assert hd(args) == "rev-parse"
      {:error, "fatal: not a git repository"}
    end

    assert {:error, reason} = StepSnapshot.record(sid, root, git: git_fn)
    assert is_binary(reason)
    assert reason =~ "git"
  end

  test "revert more than recorded errors", %{root: root, sid: sid} do
    File.write!(Path.join(root, "file.txt"), "v1\n")
    assert {:ok, _} = StepSnapshot.record(sid, root)

    assert {:error, reason} = StepSnapshot.revert(sid, 2, cwd: root)
    assert reason =~ "recorded"
  end

  test "revert with nothing recorded errors", %{root: root, sid: sid} do
    assert {:error, reason} = StepSnapshot.revert(sid, 1, cwd: root)
    assert reason =~ "recorded"
  end

  test "does not commit on the user branch or create a named branch", %{root: root, sid: sid} do
    head_before = git!(root, ["rev-parse", "HEAD"])
    branch_before = git!(root, ["rev-parse", "--abbrev-ref", "HEAD"])

    File.write!(Path.join(root, "file.txt"), "v1\n")
    assert {:ok, snap} = StepSnapshot.record(sid, root)

    assert git!(root, ["rev-parse", "HEAD"]) == head_before
    assert git!(root, ["rev-parse", "--abbrev-ref", "HEAD"]) == branch_before

    refs = git!(root, ["show-ref"])
    assert refs =~ snap.ref
    refute refs =~ "refs/heads/osa-step"
  end

  test "does not rewrite updates.jsonl on revert", %{root: root, sid: sid} do
    transcript = Path.join(root, "updates.jsonl")
    original = ~s({"type":"message","text":"keep me"}\n)
    File.write!(transcript, original)

    File.write!(Path.join(root, "file.txt"), "v1\n")
    assert {:ok, _} = StepSnapshot.record(sid, root)
    File.write!(Path.join(root, "file.txt"), "v2\n")
    assert {:ok, _} = StepSnapshot.record(sid, root)

    assert {:ok, result} = StepSnapshot.revert(sid, 1, cwd: root)
    assert result.transcript_rewritten == false
    assert File.read!(transcript) == original
  end

  test "rejects paths outside cwd", %{root: root, sid: sid} do
    outside =
      Path.join(System.tmp_dir!(), "osa-step-outside-#{System.unique_integer([:positive])}")

    File.write!(outside, "secret\n")
    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, reason} = StepSnapshot.record(sid, root, paths: [outside])
    assert reason =~ "cwd"
  end

  test "scoped paths leave unrelated dirty files out of the snapshot tree", %{
    root: root,
    sid: sid
  } do
    File.write!(Path.join(root, "file.txt"), "tracked-v1\n")
    File.write!(Path.join(root, "other.txt"), "other-v1\n")

    assert {:ok, _} = StepSnapshot.record(sid, root, paths: ["file.txt"])

    File.write!(Path.join(root, "file.txt"), "tracked-v2\n")
    File.write!(Path.join(root, "other.txt"), "other-v2\n")
    assert {:ok, _} = StepSnapshot.record(sid, root, paths: ["file.txt"])

    assert {:ok, _} = StepSnapshot.revert(sid, 1, cwd: root)
    assert File.read!(Path.join(root, "file.txt")) == "tracked-v1\n"
    assert File.read!(Path.join(root, "other.txt")) == "other-v2\n"
  end

  test "revert 1 after a new file in step 2 removes that file", %{root: root, sid: sid} do
    File.write!(Path.join(root, "file.txt"), "v1\n")
    assert {:ok, _} = StepSnapshot.record(sid, root)

    File.write!(Path.join(root, "file.txt"), "v2\n")
    File.write!(Path.join(root, "added.txt"), "new\n")
    assert {:ok, _} = StepSnapshot.record(sid, root, paths: ["file.txt", "added.txt"])

    assert {:ok, _} = StepSnapshot.revert(sid, 1, cwd: root)
    assert File.read!(Path.join(root, "file.txt")) == "v1\n"
    refute File.exists?(Path.join(root, "added.txt"))
  end

  test "list is empty for an unknown session" do
    assert StepSnapshot.list("nobody-#{System.unique_integer([:positive])}") == []
  end

  test "revert survives ETS loss by reading hidden refs", %{root: root, sid: sid} do
    path = Path.join(root, "file.txt")
    File.write!(path, "v1\n")
    assert {:ok, _} = StepSnapshot.record(sid, root)
    File.write!(path, "v2\n")
    assert {:ok, _} = StepSnapshot.record(sid, root)
    assert File.read!(path) == "v2\n"

    :ets.delete(:osa_step_snapshots, sid)
    assert StepSnapshot.list(sid) == []

    recovered = StepSnapshot.list(sid, cwd: root)
    assert Enum.map(recovered, & &1.n) == [1, 2]

    assert {:ok, result} = StepSnapshot.revert(sid, 1, cwd: root)
    assert result.restored_n == 1
    assert File.read!(path) == "v1\n"
  end

  defp init_repo do
    root = Path.join(System.tmp_dir!(), "osa-step-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    git!(root, ["init", "-b", "main"])
    git!(root, ["config", "user.email", "osa-test@example.com"])
    git!(root, ["config", "user.name", "OSA Test"])
    git!(root, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(root, "file.txt"), "v0\n")
    git!(root, ["add", "file.txt"])
    git!(root, ["commit", "-m", "init"])

    root
  end

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(out)
  end
end
