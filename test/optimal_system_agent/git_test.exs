defmodule OptimalSystemAgent.GitTest do
  @moduledoc """
  Security regression tests for `OptimalSystemAgent.Git`.

  The integration block builds a genuinely hostile repository — the kind OSA
  clones into a worktree or points context discovery at — and asserts that
  plain `System.cmd("git", ...)` executes the attacker's code while
  `OptimalSystemAgent.Git.cmd/2` does not.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Git

  # ── Flag construction ─────────────────────────────────────────────────

  describe "hardening_args/3" do
    test "disables hooks and fsmonitor by default" do
      args = Git.hardening_args(["status"], [cd: hostile_repo()], [])
      assert "-c" in args
      assert "core.hooksPath=/dev/null" in args
      assert "core.fsmonitor=false" in args
      assert "--no-pager" in args
    end

    test "hooks: :enabled keeps the repo's hooks but still kills fsmonitor" do
      args = Git.hardening_args(["commit"], [cd: hostile_repo()], hooks: :enabled)
      refute "core.hooksPath=/dev/null" in args
      assert "core.fsmonitor=false" in args
    end

    test "blanks every executable clean/smudge/process filter driver the repo configures" do
      Git.__reset_cache__()
      args = Git.hardening_args(["status"], [cd: hostile_repo()], [])
      assert "filter.evil.clean=" in args
      assert "filter.evil.smudge=" in args
    end
  end

  describe "harden_diff_args/2" do
    test "inserts --no-ext-diff/--no-textconv after diff-family subcommands" do
      assert Git.harden_diff_args(["diff", "--cached"]) ==
               ["diff", "--no-ext-diff", "--no-textconv", "--cached"]

      assert Git.harden_diff_args(["log", "--oneline", "-3"]) ==
               ["log", "--no-ext-diff", "--no-textconv", "--oneline", "-3"]

      assert Git.harden_diff_args(["show", "--stat", "--patch", "abc"]) ==
               ["show", "--no-ext-diff", "--no-textconv", "--stat", "--patch", "abc"]
    end

    test "skips the subcommand's own global options (git -C dir diff)" do
      assert Git.harden_diff_args(["-C", "/tmp", "diff"]) ==
               ["-C", "/tmp", "diff", "--no-ext-diff", "--no-textconv"]
    end

    test "leaves non-diff subcommands untouched" do
      for args <- [
            ["status", "--porcelain"],
            ["rev-parse", "--show-toplevel"],
            ["worktree", "list", "--porcelain"],
            ["branch", "--show-current"],
            ["add", "-A"]
          ] do
        assert Git.harden_diff_args(args) == args
      end
    end

    test "does not duplicate flags a caller already passed" do
      assert Git.harden_diff_args(["diff", "--no-ext-diff"]) ==
               ["diff", "--no-textconv", "--no-ext-diff"]
    end
  end

  # ── The actual hole ───────────────────────────────────────────────────

  describe "repository-config code execution" do
    test "plain System.cmd in a hostile repo executes attacker code (the hole)" do
      repo = hostile_repo()
      {out, _} = System.cmd("git", ["status", "--porcelain"], cd: repo, stderr_to_stdout: true)
      assert out =~ "PWNED-FSMON", "baseline: unhardened git must reproduce the RCE"

      {out, _} = System.cmd("git", ["diff"], cd: repo, stderr_to_stdout: true)
      assert out =~ "PWNED-CLEAN" or out =~ "PWNED-EXTDIFF" or out =~ "PWNED-TEXTCONV"
    end

    test "Git.cmd/2 executes none of it" do
      Git.__reset_cache__()
      repo = hostile_repo()

      for args <- [
            ["status", "--porcelain"],
            ["diff"],
            ["diff", "--cached"],
            ["log", "--oneline", "-3"],
            ["rev-parse", "--show-toplevel"],
            ["branch", "--show-current"],
            ["status", "--porcelain", "-z"]
          ] do
        {out, _status} = Git.cmd(args, cd: repo, stderr_to_stdout: true)
        refute out =~ "PWNED", "git #{Enum.join(args, " ")} leaked: #{out}"
      end
    end

    test "hooks: :enabled still blocks the non-hook vectors" do
      Git.__reset_cache__()
      {out, _} = Git.cmd(["diff"], cd: hostile_repo(), stderr_to_stdout: true, hooks: :enabled)
      refute out =~ "PWNED-FSMON"
      refute out =~ "PWNED-CLEAN"
      refute out =~ "PWNED-EXTDIFF"
      refute out =~ "PWNED-TEXTCONV"
    end

    test "hardening does not change git's output" do
      Git.__reset_cache__()
      repo = benign_repo()

      for args <- [["status", "--porcelain"], ["diff"], ["log", "--oneline", "-3"]] do
        {plain, s1} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
        {hardened, s2} = Git.cmd(args, cd: repo, stderr_to_stdout: true)
        assert plain == hardened, "git #{Enum.join(args, " ")} output changed"
        assert s1 == s2
      end
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp hostile_repo do
    build_repo("osa_git_hostile", fn dir ->
      evil = Path.join(dir, "evil")
      File.mkdir_p!(evil)
      hook = Path.join(evil, "pre-commit")
      File.write!(hook, "#!/bin/sh\necho PWNED-HOOK >&2\n")
      File.chmod!(hook, 0o755)

      git!(dir, ["config", "core.hooksPath", evil])
      git!(dir, ["config", "core.fsmonitor", "sh -c 'echo PWNED-FSMON >&2; false'"])
      git!(dir, ["config", "filter.evil.clean", "sh -c 'echo PWNED-CLEAN >&2; cat'"])
      git!(dir, ["config", "filter.evil.smudge", "cat"])
      git!(dir, ["config", "diff.external", "sh -c 'echo PWNED-EXTDIFF >&2'"])
      git!(dir, ["config", "diff.evil.textconv", "sh -c 'echo PWNED-TEXTCONV >&2; cat'"])
      File.write!(Path.join(dir, ".gitattributes"), "tracked.txt filter=evil diff=evil\n")
    end)
  end

  defp benign_repo, do: build_repo("osa_git_benign", fn _dir -> :ok end)

  defp build_repo(name, poison) do
    # Scoped to THIS OS process: two concurrent `mix test` runs used to derive
    # the identical phash2-only path, and one run's rebuild (rm_rf + re-init)
    # tore the repo out from under the other — a half-built fixture (no
    # .git/config, empty evil/) then failed the security assertions with the
    # hardening looking guilty when it was innocent. Same convention
    # topology_test uses for its fixtures.
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{name}_#{System.pid()}_#{:erlang.phash2(name)}"
      )

    if not File.dir?(Path.join(dir, ".git")) do
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      git!(dir, ["init", "-q", "."])
      git!(dir, ["config", "user.email", "osa@example.invalid"])
      git!(dir, ["config", "user.name", "osa-test"])
      File.write!(Path.join(dir, "tracked.txt"), "hello\n")
      git!(dir, ["add", "tracked.txt"])
      git!(dir, ["commit", "-qm", "init", "--no-verify"])
      # Leave a dirty worktree so `git diff` has something to filter.
      File.write!(Path.join(dir, "tracked.txt"), "hello\nworld\n")
      poison.(dir)
    end

    dir
  end

  defp git!(dir, args) do
    {_out, _status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    :ok
  end
end
