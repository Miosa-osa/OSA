defmodule OptimalSystemAgent.Verification.WorkspaceFingerprintTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Verification.WorkspaceFingerprint, as: FP

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_fp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@t"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: dir)
    File.write!(Path.join(dir, "a.txt"), "one\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-qm", "init"], cd: dir)

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "capture/1" do
    test "is stable across repeated calls on an untouched worktree", %{dir: dir} do
      assert {:ok, h1} = FP.capture(dir)
      assert {:ok, ^h1} = FP.capture(dir)
    end

    test "returns :unknown outside a git repository" do
      dir = Path.join(System.tmp_dir!(), "osa_fp_nogit_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert FP.capture(dir) == :unknown
    end

    test "returns :unknown for a path that does not exist" do
      assert FP.capture("/nonexistent/osa/fingerprint/path") == :unknown
    end
  end

  # These are the tests that matter. `unchanged?/2` returning TRUE when
  # something did change is the failure that silently halts real work, so every
  # kind of change gets its own case.
  describe "unchanged?/2 is false whenever anything changed" do
    test "editing a tracked file", %{dir: dir} do
      before = FP.capture(dir)
      File.write!(Path.join(dir, "a.txt"), "two\n")
      refute FP.unchanged?(FP.capture(dir), before)
    end

    test "creating an untracked file", %{dir: dir} do
      before = FP.capture(dir)
      File.write!(Path.join(dir, "new_test.exs"), "assert true\n")
      refute FP.unchanged?(FP.capture(dir), before)
    end

    test "rewriting the CONTENT of an already-untracked file", %{dir: dir} do
      File.write!(Path.join(dir, "new_test.exs"), "attempt one\n")
      before = FP.capture(dir)

      File.write!(Path.join(dir, "new_test.exs"), "attempt two\n")

      # `git diff HEAD` says nothing about untracked content and `git status`
      # reports the identical `?? new_test.exs` line both times. Only the
      # untracked-content read separates these.
      refute FP.unchanged?(FP.capture(dir), before)
    end

    test "deleting a tracked file", %{dir: dir} do
      before = FP.capture(dir)
      File.rm!(Path.join(dir, "a.txt"))
      refute FP.unchanged?(FP.capture(dir), before)
    end

    test "deleting an untracked file", %{dir: dir} do
      File.write!(Path.join(dir, "scratch.txt"), "x\n")
      before = FP.capture(dir)
      File.rm!(Path.join(dir, "scratch.txt"))
      refute FP.unchanged?(FP.capture(dir), before)
    end

    test "staging an existing edit", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "two\n")
      before = FP.capture(dir)
      {_, 0} = System.cmd("git", ["add", "a.txt"], cd: dir)
      refute FP.unchanged?(FP.capture(dir), before)
    end

    test "a change to a binary file", %{dir: dir} do
      File.write!(Path.join(dir, "b.bin"), <<0, 1, 2>>)
      {_, 0} = System.cmd("git", ["add", "."], cd: dir)
      {_, 0} = System.cmd("git", ["commit", "-qm", "bin"], cd: dir)

      before = FP.capture(dir)
      File.write!(Path.join(dir, "b.bin"), <<0, 1, 3>>)
      refute FP.unchanged?(FP.capture(dir), before)
    end

    test "renaming an untracked file without changing its bytes", %{dir: dir} do
      File.write!(Path.join(dir, "x.txt"), "same\n")
      before = FP.capture(dir)
      File.rename!(Path.join(dir, "x.txt"), Path.join(dir, "y.txt"))
      refute FP.unchanged?(FP.capture(dir), before)
    end
  end

  describe "unchanged?/2 fails open" do
    test "true only when both sides are known and equal", %{dir: dir} do
      fp = FP.capture(dir)
      assert FP.unchanged?(fp, fp)
    end

    test ":unknown on either side never reports unchanged", %{dir: dir} do
      fp = FP.capture(dir)
      refute FP.unchanged?(:unknown, fp)
      refute FP.unchanged?(fp, :unknown)
      refute FP.unchanged?(:unknown, :unknown)
    end
  end

  test "refusal_message/1 names the command and does not read as a retryable error" do
    msg = FP.refusal_message("mix test")
    assert msg =~ "mix test"
    assert msg =~ "workspace has not changed"
  end
end
