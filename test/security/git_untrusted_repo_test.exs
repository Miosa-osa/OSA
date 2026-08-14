defmodule OptimalSystemAgent.Security.GitUntrustedRepoTest do
  @moduledoc """
  Git executes programs named by the *repository's own* configuration.

  A repository OSA did not author — a benchmark checkout, a tarball, a
  submodule, a directory the operator was handed — can carry:

    * `.git/hooks/*` (post-checkout, pre-merge-commit, post-merge, …),
    * `.git/config` `core.fsmonitor`, which git spawns on ordinary
      worktree-reading commands and which needs **no hook file at all**,
    * `.gitattributes` + `diff.<driver>.textconv`, which runs while diffing.

  `OptimalSystemAgent.Git` exists precisely to neutralize these with `-c`
  overrides. The defect this file pins down is that several call sites bypassed
  it and called `System.cmd("git", …)` raw, so the hardening was real but not
  universal. `Workspace.Topology` — reached on ordinary workspace discovery,
  before the operator has approved anything — ran `git check-ignore` raw, and
  `check-ignore` honours `core.fsmonitor`.

  Every assertion here is a *measurement*: the payload writes a marker file and
  the test looks for it on disk.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.EnterWorktree
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Workspace.Topology

  @moduletag :security

  setup do
    base = Path.join(System.tmp_dir!(), "osa_git_trap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    OptimalSystemAgent.Git.__reset_cache__()
    {:ok, base: base}
  end

  # ── Trap repository ───────────────────────────────────────────────────

  # A repo carrying all three repo-controlled execution vectors. Each vector
  # writes its own marker so a partial fix cannot pass by accident.
  defp trap_repo(base) do
    repo = Path.join(base, "victim")
    File.mkdir_p!(Path.join(repo, "src"))
    File.mkdir_p!(Path.join(repo, "docs"))

    git!(repo, ["init", "-q", "."])
    git!(repo, ["config", "user.email", "trap@example.invalid"])
    git!(repo, ["config", "user.name", "trap"])

    File.write!(Path.join(repo, "f.txt"), "hello\n")
    File.write!(Path.join(repo, "src/a.txt"), "a\n")
    File.write!(Path.join(repo, ".gitignore"), "ignored_dir/\n")
    File.mkdir_p!(Path.join(repo, "ignored_dir"))
    File.write!(Path.join(repo, "ignored_dir/x.txt"), "x\n")

    # Vector 1 — core.fsmonitor. No hook file needed; fires on read-only
    # porcelain (status, diff, check-ignore, add).
    git!(repo, ["config", "core.fsmonitor", "touch #{marker(base, "FSMONITOR")}; false"])

    # Vector 2 — a checkout/merge hook.
    hooks = Path.join(repo, ".git/hooks")
    File.mkdir_p!(hooks)

    for hook <- ~w(post-checkout post-merge pre-merge-commit) do
      path = Path.join(hooks, hook)
      File.write!(path, "#!/bin/sh\ntouch #{marker(base, "HOOK")}\n")
      File.chmod!(path, 0o755)
    end

    # Vector 3 — .gitattributes selecting a textconv driver.
    File.write!(Path.join(repo, ".gitattributes"), "f.txt diff=evil\n")
    git!(repo, ["config", "diff.evil.textconv", "touch #{marker(base, "TEXTCONV")}; cat"])

    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-qm", "init"])

    repo
  end

  defp marker(base, name), do: Path.join(base, "MARKER_#{name}")

  defp fired(base) do
    base
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "MARKER_"))
    |> Enum.sort()
  end

  defp clear_markers(base) do
    for f <- fired(base), do: File.rm(Path.join(base, f))
    :ok
  end

  # The trap repo must be built WITHOUT triggering its own payload, so this
  # helper deliberately uses the hardened wrapper.
  defp git!(cwd, args) do
    {out, status} = OptimalSystemAgent.Git.cmd(args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, "git #{inspect(args)} failed: #{out}"
    :ok
  end

  # ── Premise ───────────────────────────────────────────────────────────

  describe "premise: the payload really does execute under plain git" do
    test "raw `git check-ignore` in the trap repo runs core.fsmonitor", %{base: base} do
      repo = trap_repo(base)
      clear_markers(base)

      System.cmd("git", ["check-ignore", "--", "src", "docs"],
        cd: repo,
        stderr_to_stdout: true
      )

      assert "MARKER_FSMONITOR" in fired(base),
             "premise failed — this git build does not honour core.fsmonitor on check-ignore, " <>
               "so the rest of this file proves nothing"
    end

    test "raw `git worktree add` in the trap repo runs post-checkout", %{base: base} do
      repo = trap_repo(base)
      clear_markers(base)

      System.cmd("git", ["worktree", "add", Path.join(base, "raw_wt"), "-b", "rawb"],
        cd: repo,
        stderr_to_stdout: true
      )

      assert "MARKER_HOOK" in fired(base), "premise failed — post-checkout did not fire"
    end

    test "raw `git diff HEAD` in the trap repo runs the textconv driver", %{base: base} do
      repo = trap_repo(base)
      File.write!(Path.join(repo, "f.txt"), "changed\n")
      clear_markers(base)

      System.cmd("git", ["diff", "HEAD"], cd: repo, stderr_to_stdout: true)

      assert "MARKER_TEXTCONV" in fired(base), "premise failed — textconv did not fire"
    end
  end

  # ── The hardened wrapper itself ───────────────────────────────────────

  describe "OptimalSystemAgent.Git.cmd/2 neutralizes all three vectors" do
    test "status, check-ignore, diff and worktree add all run clean", %{base: base} do
      repo = trap_repo(base)
      File.write!(Path.join(repo, "f.txt"), "changed\n")

      for args <- [
            ["status", "--porcelain"],
            ["check-ignore", "--", "src", "docs"],
            ["diff", "HEAD"],
            ["add", "-A"]
          ] do
        clear_markers(base)
        OptimalSystemAgent.Git.cmd(args, cd: repo, stderr_to_stdout: true)

        assert fired(base) == [],
               "git #{inspect(args)} executed repo-controlled code: #{inspect(fired(base))}"
      end

      clear_markers(base)

      OptimalSystemAgent.Git.cmd(["worktree", "add", Path.join(base, "safe_wt"), "-b", "safeb"],
        cd: repo,
        stderr_to_stdout: true
      )

      assert fired(base) == [], "worktree add executed repo-controlled code"
    end
  end

  # ── The call sites ────────────────────────────────────────────────────

  describe "workspace discovery against an untrusted repo" do
    test "Topology.detect/2 does not execute repo-controlled code", %{base: base} do
      repo = trap_repo(base)
      Topology.invalidate(:all)
      clear_markers(base)

      Topology.detect(repo)

      assert fired(base) == [],
             "Workspace.Topology executed the repo's core.fsmonitor command " <>
               "during ordinary workspace discovery: #{inspect(fired(base))}"
    end

    # The hardening must not turn `check-ignore` into a no-op. `reject_ignored/2`
    # fails *open* (returns every name) on any error, so a broken invocation
    # would look identical to "nothing is ignored" — silently scanning ignored
    # trees rather than crashing. Comparing the scan against the same repo with
    # gitignore handling switched off is what actually distinguishes the two.
    test "and still honours .gitignore (the hardening must not blind it)", %{base: base} do
      repo = trap_repo(base)

      Topology.invalidate(:all)
      respected = Topology.detect(repo)

      Topology.invalidate(:all)
      ignored_off = Topology.detect(repo, respect_gitignore: false)

      assert respected.scanned_dirs < ignored_off.scanned_dirs,
             "check-ignore stopped excluding anything: scanned #{respected.scanned_dirs} dirs " <>
               "with gitignore respected vs #{ignored_off.scanned_dirs} without — the hardened " <>
               "invocation is failing open"

      refute Enum.any?(component_paths(respected), &String.contains?(&1, "ignored_dir")),
             "a gitignored directory leaked into the topology"
    end
  end

  describe "enter_worktree against an untrusted repo" do
    test "does not run the repo's post-checkout hook", %{base: base} do
      repo = trap_repo(base)
      ctx = %UseContext{extras: %{cwd: repo}}
      clear_markers(base)

      result =
        EnterWorktree.Handler.execute(
          %{"branch" => "osa-trap-wt", "path" => Path.join(base, "osa_wt")},
          ctx
        )

      assert match?({:ok, _}, result), "worktree creation itself must still work: #{inspect(result)}"

      assert fired(base) == [],
             "enter_worktree executed repo-controlled code: #{inspect(fired(base))}"
    end
  end

  # ── Structural invariant ──────────────────────────────────────────────

  describe "no call site bypasses the hardened wrapper" do
    # Runtime coverage above cannot reach every site (some are deep in the agent
    # loop). This is the backstop: the raw form must not reappear.
    test "lib/ contains no raw System.cmd(\"git\", …)" do
      root = Path.expand("../..", __DIR__)

      offenders =
        Path.wildcard(Path.join(root, "lib/**/*.ex"))
        |> Enum.reject(&String.ends_with?(&1, "/git.ex"))
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          # Prose mentions of the raw form are fine and deliberate — `git.ex`'s
          # own docs and the finalizer's `git_fun` docstring both name it to
          # explain what they replace. Those are always inside backticks or a
          # `#` comment; a real call site is neither.
          |> Enum.filter(fn {line, _} ->
            trimmed = String.trim_leading(line)

            String.contains?(line, ~s(System.cmd("git")) and
              not String.contains?(line, "`") and
              not String.starts_with?(trimmed, "#")
          end)
          |> Enum.map(fn {_, idx} -> "#{Path.relative_to(file, root)}:#{idx}" end)
        end)

      assert offenders == [],
             "these sites bypass OptimalSystemAgent.Git and inherit the repo's " <>
               "hooks/fsmonitor/textconv:\n  " <> Enum.join(offenders, "\n  ")
    end
  end

  defp component_paths(topo) do
    topo
    |> Map.get(:components, [])
    |> Enum.map(fn c -> Map.get(c, :path) || Map.get(c, :root) || "" end)
    |> Enum.reject(&(&1 == ""))
  end
end
