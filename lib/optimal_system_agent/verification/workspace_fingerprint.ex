defmodule OptimalSystemAgent.Verification.WorkspaceFingerprint do
  @moduledoc """
  A content hash of the working tree, used to refuse re-running a gate that
  cannot possibly produce a different answer.

  Ported from Prime Agent's autonomous no-op detector
  (`core/autonomous.ts:294-311, 374-444`, MIT — see
  `docs/research/prime-agent.md` §6.3). The mechanism is the whole point: it is
  mechanical, so a model cannot argue with it, and it costs one `git` call.

  ## The failure it kills

  `Verification.Loop` runs `test_command` → fails → asks a model for a fix →
  applies it → runs `test_command` again. When the "fix" changes nothing on
  disk — the model answered with prose instead of `$ ` commands, or every
  command it emitted was refused by the permission gate, or it re-suggested an
  edit already made — the next iteration is a full test run whose result is
  known in advance. OSA has burned whole benchmark budgets that way.

  ## What it proves, and what it does not

  It proves *something changed*. It does not prove the change was relevant, and
  it must not be read as evidence of progress. It is the cheap half of a
  problem whose expensive half (`Loop.GoalVerifier`'s skeptic panel) is
  unaffected by this module.

  ## Fail-open, deliberately

  `capture/1` returns `:unknown` — never a hash — when the workspace is not a
  git repository, `git` is missing, the command fails, or it exceeds
  `@timeout_ms`. `unchanged?/2` treats `:unknown` on either side as "cannot
  tell", which means PROCEED.

  That asymmetry is the entire safety argument. A false negative costs one
  redundant test run. A false positive halts a loop that was making real
  progress, and does it silently, which is the direction every rejected
  detector in this codebase has failed on. So every path that is not a
  positively-verified byte-identical match resolves to "run it".

  ## What is hashed

  Three `git` reads over the workspace, concatenated and SHA-256'd:

    * `git status --porcelain -z -uall` — which paths are modified, staged,
      untracked or deleted. Catches creation and deletion, which a diff of
      tracked content alone does not.
    * `git diff --binary HEAD` — the exact content of every tracked change,
      staged or not. `--binary` so a change to a non-text file still alters the
      hash rather than collapsing to "Binary files differ".
    * the bytes of every untracked file named by the status read, each keyed by
      path.

  The third read is what makes the fingerprint honest for the common case of a
  model creating a new test file: `git diff HEAD` says nothing about untracked
  content, so without it a loop that rewrites the same new file over and over
  would be judged unchanged. It is bounded by `@max_untracked_bytes` — beyond
  that the capture degrades to `:unknown` (proceed) rather than to a hash over
  a truncated read, because a hash of a partial view can collide across genuine
  changes, and a collision here is the false positive.
  """

  require Logger

  alias OptimalSystemAgent.Git

  @timeout_ms 15_000
  @max_untracked_bytes 32 * 1024 * 1024

  @type t :: {:ok, binary()} | :unknown

  @doc """
  Fingerprint the working tree at `dir` (default: the agent's cwd).

  Returns `{:ok, hex_sha256}` or `:unknown`. Never raises.
  """
  @spec capture(String.t() | nil) :: t()
  def capture(dir \\ nil) do
    dir = dir || OptimalSystemAgent.Workspace.Cwd.get()

    with true <- is_binary(dir) and File.dir?(dir),
         {:ok, status} <- git(dir, ["status", "--porcelain", "-z", "-uall"]),
         {:ok, diff} <- git(dir, ["diff", "--binary", "HEAD"]),
         {:ok, untracked} <- hash_untracked(dir, status) do
      digest =
        :crypto.hash_init(:sha256)
        |> :crypto.hash_update(status)
        |> :crypto.hash_update(diff)
        |> :crypto.hash_update(untracked)
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, digest}
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  @doc """
  True only when both fingerprints are known AND byte-identical.

  Any `:unknown` yields `false` — see the fail-open note in the module doc.
  """
  @spec unchanged?(t(), t()) :: boolean()
  def unchanged?({:ok, a}, {:ok, b}) when is_binary(a) and is_binary(b), do: a == b
  def unchanged?(_, _), do: false

  @doc """
  The message handed back when a re-run is refused.

  Kept close to Prime Agent's wording because it is doing the same job: it has
  to tell the model that the absence of a re-run is a statement about the
  workspace, not a transient error it should retry through.
  """
  @spec refusal_message(String.t()) :: String.t()
  def refusal_message(command) do
    "The verification command `#{command}` was not re-run because the workspace has not " <>
      "changed since this failure — no file was created, edited or deleted, so the result " <>
      "would be identical. Edit source files, tests, or record a blocker before attempting " <>
      "to finish again."
  end

  # ── Private ───────────────────────────────────────────────────────────────

  # `OptimalSystemAgent.Git.cmd/2`, never a raw `System.cmd("git", …)`.
  #
  # This module reads a worktree the agent did not necessarily author — a
  # benchmark checkout, a tarball, a directory the operator was handed — and
  # `git status` and `git diff` are exactly the read-only porcelain that fires a
  # repository's own `core.fsmonitor`, hooks, and `diff.<driver>.textconv`. A
  # raw call here would have handed a hostile repo code execution on every
  # verification iteration. `Git.cmd/2` applies the `-c` overrides and the
  # diff-family `--no-ext-diff --no-textconv` flags that neutralize all three;
  # `test/security/git_untrusted_repo_test.exs` fails if any `lib/` call site
  # goes around it.
  # Bounded, because `capture/1` is called from inside the `Verification.Loop`
  # GenServer: a `git` that wedges (a stale index.lock, a network-backed
  # worktree) would otherwise block the loop indefinitely, and it would do so on
  # the path whose entire purpose is to SAVE work. A timeout degrades to
  # `:unknown`, which proceeds.
  defp git(dir, args) do
    task =
      Task.async(fn ->
        Git.cmd(args, cd: dir, stderr_to_stdout: false, env: env())
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, out}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # `git` inherits a pager and locale from the environment; both can rewrite
  # the bytes we are hashing. Pin them so an unrelated shell setting cannot
  # make two identical worktrees fingerprint differently (a false NEGATIVE, so
  # merely wasteful) or, via a paginated truncation, identically (a false
  # POSITIVE, which is the one that must not happen).
  defp env do
    [
      {"GIT_PAGER", "cat"},
      {"GIT_OPTIONAL_LOCKS", "0"},
      {"LC_ALL", "C"},
      {"GIT_CONFIG_NOSYSTEM", "1"}
    ]
  end

  # Untracked paths come out of the `-z` status as NUL-separated `?? <path>`
  # records. Directories are impossible here because `-uall` expands them to
  # individual files.
  defp hash_untracked(dir, status) do
    paths =
      status
      |> String.split(<<0>>, trim: true)
      |> Enum.filter(&String.starts_with?(&1, "?? "))
      |> Enum.map(&String.slice(&1, 3..-1//1))
      |> Enum.sort()

    Enum.reduce_while(paths, {:ok, "", 0}, fn rel, {:ok, acc, bytes} ->
      full = Path.join(dir, rel)

      case File.read(full) do
        {:ok, content} when byte_size(content) + bytes <= @max_untracked_bytes ->
          {:cont, {:ok, acc <> rel <> <<0>> <> content <> <<0>>, bytes + byte_size(content)}}

        {:ok, _too_big} ->
          # Refuse to hash a partial view — see the module doc.
          {:halt, :error}

        # An unreadable path (a dangling symlink, a permissions hole, or a file
        # deleted between the status read and this read) is still EVIDENCE: its
        # name goes into the hash so its appearance or disappearance registers,
        # even though its content cannot.
        {:error, reason} ->
          {:cont, {:ok, acc <> rel <> <<0>> <> "!" <> to_string(reason) <> <<0>>, bytes}}
      end
    end)
    |> case do
      {:ok, acc, _bytes} -> {:ok, acc}
      :error -> :error
    end
  end
end
