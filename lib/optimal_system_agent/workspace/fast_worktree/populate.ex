defmodule OptimalSystemAgent.Workspace.FastWorktree.Populate do
  @moduledoc """
  Worktree population strategies (the "tiers") for `FastWorktree`.

  Each tier takes an already-registered `git worktree add --no-checkout`
  directory and fills it with the source repo's *current working-tree* contents
  (tracked-and-possibly-dirty files + untracked-non-ignored files), then
  finalizes the git index so `git status` is instant. Because the worktree's
  index still points at HEAD, mirroring the source working tree makes the new
  worktree reflect the source's uncommitted state — the whole point of grok
  fast-worktree over a clean `git worktree add`.

  Tier ladder (fastest → most-portable), mirroring grok's
  overlay → btrfs → reflink-copy → plain-copy:

    * `:btrfs`   — `btrfs subvolume snapshot` (O(1); only on a btrfs subvolume)
    * `:reflink` — per-file `cp --reflink=always` (CoW extent sharing; XFS/btrfs)
    * `:copy`    — parallel plain file copy (works on every filesystem)

  Every tier returns `:ok | :unsupported | {:error, reason}`. On `:unsupported`
  or `{:error, _}` the caller cleans the directory and drops to the next tier;
  the final fallback (a plain checkout `git worktree add`) lives in the parent
  module, not here.
  """

  require Logger

  @doc """
  Populate `worktree_path` from `repo_dir` using `tier`.

  `caps` is the detected `Capabilities` map, used to short-circuit tiers whose
  filesystem support is absent.
  """
  @spec run(atom(), String.t(), String.t(), map()) :: :ok | :unsupported | {:error, term()}
  def run(:btrfs, repo_dir, worktree_path, %{btrfs: true}),
    do: populate_btrfs(repo_dir, worktree_path)

  def run(:btrfs, _repo, _wt, _caps), do: :unsupported

  def run(:reflink, repo_dir, worktree_path, %{reflink: true}),
    do: populate_copy(repo_dir, worktree_path, &reflink_copy/2, :reflink)

  def run(:reflink, _repo, _wt, _caps), do: :unsupported

  def run(:copy, repo_dir, worktree_path, _caps),
    do: populate_copy(repo_dir, worktree_path, &plain_copy/2, :copy)

  def run(_other, _repo, _wt, _caps), do: :unsupported

  @doc """
  List the working-tree files to mirror: tracked files (whose on-disk content
  includes any uncommitted edits) plus untracked-but-not-ignored files. `.git`
  is never included. Returns repo-relative paths.
  """
  @spec working_tree_files(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def working_tree_files(repo_dir) do
    with {:ok, tracked} <- git_paths(repo_dir, ["ls-files", "-z"]),
         {:ok, untracked} <-
           git_paths(repo_dir, ["ls-files", "-z", "--others", "--exclude-standard"]) do
      files =
        (tracked ++ untracked)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ".git/") or &1 == ".git"))

      {:ok, files}
    end
  end

  # ── Copy-based tiers (reflink + plain) ─────────────────────────────────

  defp populate_copy(repo_dir, worktree_path, copy_fun, tier) do
    with {:ok, files} <- working_tree_files(repo_dir) do
      results =
        files
        |> Task.async_stream(
          fn rel -> copy_one(repo_dir, worktree_path, rel, copy_fun) end,
          max_concurrency: max_concurrency(),
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce({0, []}, fn
          {:ok, :ok}, {ok, errs} -> {ok + 1, errs}
          {:ok, {:error, e}}, {ok, errs} -> {ok, [e | errs]}
          {:exit, reason}, {ok, errs} -> {ok, [reason | errs]}
        end)

      case results do
        {_ok, []} ->
          Logger.debug("[fast_worktree] #{tier} populated #{length(files)} files")
          finalize_index(worktree_path)
          :ok

        {_ok, [first | _] = errs} ->
          {:error, {:copy_failed, tier, length(errs), first}}
      end
    end
  end

  defp copy_one(repo_dir, worktree_path, rel, copy_fun) do
    src = Path.join(repo_dir, rel)
    dst = Path.join(worktree_path, rel)

    cond do
      # A tracked path deleted in the working tree: mirror the deletion by not
      # copying it (git will show it as deleted, matching the source).
      not File.exists?(src) ->
        :ok

      File.dir?(src) ->
        :ok

      true ->
        File.mkdir_p!(Path.dirname(dst))
        copy_fun.(src, dst)
    end
  rescue
    e -> {:error, {rel, Exception.message(e)}}
  end

  defp plain_copy(src, dst) do
    case File.cp(src, dst) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cp, reason}}
    end
  end

  defp reflink_copy(src, dst) do
    case System.cmd("cp", ["--reflink=always", "--preserve=mode,timestamps", src, dst],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:reflink, code, String.trim(out)}}
    end
  end

  # Finalize the index of a --no-checkout worktree after populating its files.
  #
  # `git worktree add --no-checkout` leaves the worktree's index EMPTY, so the
  # copied files would otherwise show as untracked and every HEAD path as a
  # staged deletion. `git read-tree HEAD` populates the index from the HEAD tree
  # WITHOUT touching the working files we just copied — so files matching HEAD
  # read clean and genuinely-dirty files read as modified/untracked, faithfully
  # mirroring the source's working-tree state (grok's PreserveWorkingTree).
  #
  # `update-index --refresh` then warms the stat cache so the first `git status`
  # doesn't re-hash unchanged files (it exits non-zero when dirty files differ —
  # expected, so we ignore it).
  defp finalize_index(worktree_path) do
    _ = OptimalSystemAgent.Git.cmd(["read-tree", "HEAD"], cd: worktree_path, stderr_to_stdout: true)

    _ =
      OptimalSystemAgent.Git.cmd(["update-index", "-q", "--refresh"],
        cd: worktree_path,
        stderr_to_stdout: true
      )

    :ok
  rescue
    _ -> :ok
  end

  # ── btrfs tier ─────────────────────────────────────────────────────────
  #
  # Opportunistic O(1) snapshot. Only viable when the repo is itself a btrfs
  # subvolume. `git worktree add --no-checkout` has already created (and git-
  # registered) an empty `worktree_path`; a btrfs snapshot cannot target an
  # existing directory, so we snapshot into a temp subvolume and rsync-free
  # move its tracked contents in. Given btrfs is unavailable on the common
  # deployment fs, this path is best-effort and falls through cleanly on any
  # error rather than risking a half-populated tree.
  defp populate_btrfs(repo_dir, worktree_path) do
    snap = worktree_path <> ".btrfs-snap"
    _ = File.rm_rf(snap)

    case System.cmd("btrfs", ["subvolume", "snapshot", repo_dir, snap], stderr_to_stdout: true) do
      {_out, 0} ->
        try do
          with {:ok, files} <- working_tree_files(repo_dir) do
            Enum.each(files, fn rel ->
              src = Path.join(snap, rel)
              dst = Path.join(worktree_path, rel)

              if File.exists?(src) and not File.dir?(src) do
                File.mkdir_p!(Path.dirname(dst))
                # Within the same btrfs, this is itself a reflink-cheap copy.
                _ = File.cp(src, dst)
              end
            end)

            finalize_index(worktree_path)
            :ok
          end
        after
          _ = System.cmd("btrfs", ["subvolume", "delete", snap], stderr_to_stdout: true)
          _ = File.rm_rf(snap)
        end

      {out, _code} ->
        _ = File.rm_rf(snap)
        {:error, {:btrfs_snapshot, String.trim(out)}}
    end
  rescue
    e -> {:error, {:btrfs, Exception.message(e)}}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp git_paths(repo_dir, args) do
    case OptimalSystemAgent.Git.cmd(args, cd: repo_dir, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.split(out, <<0>>, trim: true)}
      {out, code} -> {:error, {:git, code, String.trim(out)}}
    end
  rescue
    e -> {:error, {:git, Exception.message(e)}}
  end

  defp max_concurrency, do: System.schedulers_online() * 4
end
