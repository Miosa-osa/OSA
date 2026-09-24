defmodule OptimalSystemAgent.RepoMap.GitState do
  @moduledoc """
  A verifiable "which checkout is this, exactly" snapshot: branch, HEAD sha,
  dirty-file count/list, and ahead/behind vs. upstream.

  Exists because a stale or wrong checkout is otherwise invisible to a model
  that only ever `file_grep`s file contents — grepping a clone 122 commits
  behind the installed release looks identical to grepping the right one
  unless something states the commit and branch plainly. This is that
  something: cheap (a handful of `git` calls, cached by `RepoMap` rather than
  re-run every turn) and unambiguous.

  Every subprocess call goes through `OptimalSystemAgent.Git.cmd/2` — the
  hardened wrapper that neutralizes a repo's own `core.hooksPath` /
  `core.fsmonitor` / filter-driver config, since this runs against whatever
  directory OSA is pointed at, not only repos OSA itself authored.
  """

  alias OptimalSystemAgent.Git

  @type t :: %{
          branch: String.t(),
          head_sha: String.t() | nil,
          head_sha_short: String.t() | nil,
          dirty_count: non_neg_integer(),
          dirty_files: [String.t()],
          ahead: non_neg_integer() | nil,
          behind: non_neg_integer() | nil,
          upstream: String.t() | nil,
          last_commit_at: String.t() | nil,
          checked_at: integer()
        }

  # Dirty-file list is a preview, not a full diff — `git status` itself is
  # cheap regardless of size, but a 5,000-file dirty tree pasted into context
  # verbatim would defeat the entire point of a COMPACT checkout summary.
  @max_dirty_files 50

  @doc """
  Snapshot `root`'s git state, or `nil` when `root` is not inside a git work
  tree. Never raises — a git failure of any kind degrades to `nil` rather
  than crashing the caller.
  """
  @spec refresh(String.t()) :: t() | nil
  def refresh(root) do
    if git_repo?(root) do
      dirty = dirty_files(root)
      upstream = upstream(root)
      {ahead, behind} = ahead_behind(root, upstream)

      %{
        branch: branch(root),
        head_sha: head_sha(root),
        head_sha_short: head_sha(root) |> short_sha(),
        dirty_count: length(dirty),
        dirty_files: Enum.take(dirty, @max_dirty_files),
        ahead: ahead,
        behind: behind,
        upstream: upstream,
        last_commit_at: last_commit_at(root),
        checked_at: System.monotonic_time(:millisecond)
      }
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp short_sha(nil), do: nil
  defp short_sha(sha), do: String.slice(sha, 0, 8)

  defp git_repo?(root) do
    case Git.cmd(["rev-parse", "--is-inside-work-tree"], cd: root, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) == "true"
      _ -> false
    end
  rescue
    _ -> false
  end

  defp branch(root) do
    case Git.cmd(["symbolic-ref", "-q", "--short", "HEAD"], cd: root, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "HEAD (detached)"
    end
  end

  defp head_sha(root) do
    case Git.cmd(["rev-parse", "HEAD"], cd: root, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  # `trim_trailing/1`, deliberately NOT `trim/1` — porcelain v1's status code
  # occupies a fixed columns 1-2 (which CAN legitimately be a leading space,
  # e.g. " M path" = unmodified-in-index, modified-in-worktree). Stripping
  # that leading space would shift the fixed-width columns and corrupt the
  # path for any consumer that parses these lines positionally, notably
  # `RepoMap.sync_from_git/1`.
  defp dirty_files(root) do
    case Git.cmd(["status", "--porcelain=v1"], cd: root, stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim_trailing/1)
      _ -> []
    end
  end

  defp upstream(root) do
    case Git.cmd(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp ahead_behind(_root, nil), do: {nil, nil}

  defp ahead_behind(root, upstream) do
    case Git.cmd(["rev-list", "--left-right", "--count", "#{upstream}...HEAD"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case out |> String.trim() |> String.split(~r/\s+/) do
          [behind, ahead] ->
            {parse_int(ahead), parse_int(behind)}

          _ ->
            {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp last_commit_at(root) do
    case Git.cmd(["log", "-1", "--format=%cI"], cd: root, stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> nil
          iso -> iso
        end

      _ ->
        nil
    end
  end
end
