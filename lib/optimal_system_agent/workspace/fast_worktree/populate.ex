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
  module, not here. The one exception is an enumeration failure
  (`Populate.fatal?/1`), which every tier would hit identically and which the
  caller must therefore surface rather than fall through — see
  `working_tree_files/1`.

  ## Submodules and embedded repositories

  Enumeration deliberately does **not** trust `git ls-files` for the shape of
  the tree: git collapses a submodule and an embedded independent repository to
  a single gitlink entry, so a naive listing silently omits their entire
  contents. `working_tree_files/1` documents how those subtrees are recovered.
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
  includes any uncommitted edits) plus untracked-but-not-ignored files, **plus
  the contents of every subtree git collapses to a single entry**. `.git` is
  never included. Returns repo-relative paths.

  ## Why this is not just `git ls-files`

  Git reports a **submodule** and an **embedded independent repository** as one
  bare *gitlink* path — a directory name where thousands of files should be:

      $ git ls-files
      .gitmodules
      README.md
      nested-repo        # ← ONE entry. Its whole tree: not listed.
      plaindir/p.txt
      vendor/subm        # ← ONE entry (gitlink). Same.

  Populating a worktree from that list creates a worktree that is *reported as
  successful and silently missing entire components*. `git status` at the parent
  then reports a dirty nested repo as clean, so nothing downstream notices.

  `git ls-files --recurse-submodules` fixes only half of it (declared
  submodules) and cannot be combined with `--others`, so it neither covers
  embedded independent repos — which are not submodules and which git will never
  descend into under any flag — nor untracked-but-not-ignored files. This
  function therefore **recurses explicitly**: it finds every collapsed subtree
  and re-runs the same enumeration inside it.

  ## Exclusions are preserved

  Each subtree is enumerated by its *own* git, with `--exclude-standard`, so its
  `.gitignore` (and `node_modules` / `_build` / `deps` / `target`) is honored
  exactly as at the top level. A subtree that is not a git repository at all
  falls back to a filesystem walk that skips the same build/vendor directories
  and asks the parent repo's `git check-ignore` about what is left — it never
  degrades into "copy everything on disk".

  ## Failure is loud

  If any subtree exists but cannot be enumerated, this returns
  `{:error, {:incomplete_enumeration, [{path, kind, reason}]}}` rather than a
  short list. Returning a successful worktree with code missing from it is the
  defect being fixed here; a partial answer is never `{:ok, _}`.
  """
  @spec working_tree_files(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def working_tree_files(repo_dir) do
    case collect(Path.expand(repo_dir), "", MapSet.new(), 0) do
      {:ok, own, subtrees, []} -> {:ok, Enum.uniq(own ++ subtrees)}
      {:ok, _own, _sub, failures} -> {:error, {:incomplete_enumeration, failures}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Only the files git hides — everything under a collapsed gitlink / embedded
  repo, and nothing that a plain `git ls-files` (or a plain `git checkout`)
  would already have produced.

  Used by the `:git` fallback tier, whose `git worktree add` checkout leaves
  every gitlink path as an **empty directory**. Filling exactly those paths adds
  the missing components without touching anything the checkout wrote.
  """
  @spec hidden_subtree_files(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def hidden_subtree_files(repo_dir) do
    case collect(Path.expand(repo_dir), "", MapSet.new(), 0) do
      {:ok, _own, subtrees, []} -> {:ok, Enum.uniq(subtrees)}
      {:ok, _own, _sub, failures} -> {:error, {:incomplete_enumeration, failures}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Copy the hidden-subtree files of `repo_dir` into an already-checked-out
  `worktree_path`. Returns `:ok` when there is nothing hidden.
  """
  @spec fill_hidden_subtrees(String.t(), String.t()) :: :ok | {:error, term()}
  def fill_hidden_subtrees(repo_dir, worktree_path) do
    with {:ok, files} <- hidden_subtree_files(repo_dir) do
      case copy_all(repo_dir, worktree_path, files, &plain_copy/2) do
        {_ok, []} ->
          if files != [],
            do: Logger.info("[fast_worktree] filled #{length(files)} files git hid from checkout")

          :ok

        {_ok, [first | _] = errs} ->
          {:error, {:copy_failed, :subtree_fill, length(errs), first}}
      end
    end
  end

  @doc """
  True when `reason` means the source tree could not be fully enumerated.

  Such a failure is *not* a tier problem — no other tier can enumerate it either
  — so the caller must abort rather than fall through to a tier that would
  "succeed" with code missing.
  """
  @spec fatal?(term()) :: boolean()
  def fatal?({:incomplete_enumeration, _}), do: true
  def fatal?(_), do: false

  # ── Enumeration ────────────────────────────────────────────────────────
  #
  # Returns {:ok, own_files, subtree_files, failures}. `prefix` is the path of
  # `dir` relative to the ORIGINAL repo root (""/"vendor/subm/"), so every path
  # handed back is root-relative regardless of recursion depth. `seen` guards
  # against symlinked cycles; `depth` is a belt-and-braces bound.

  # A submodule holding a submodule holding a submodule is real; ten levels is
  # not, and an unbounded recursion on a pathological tree is worse than a miss
  # we can report.
  @max_subtree_depth 8

  defp collect(_dir, prefix, _seen, depth) when depth > @max_subtree_depth,
    do: {:ok, [], [], [{prefix, :too_deep, "exceeded #{@max_subtree_depth} nested repos"}]}

  defp collect(dir, prefix, seen, depth) do
    real = real_path(dir)

    if MapSet.member?(seen, real) do
      # Already enumerated via another path (symlink loop) — not an error.
      {:ok, [], [], []}
    else
      seen = MapSet.put(seen, real)

      with {:ok, tracked_files, gitlinks} <- tracked_entries(dir),
           {:ok, other_files, other_dirs} <- untracked_entries(dir) do
        own =
          (tracked_files ++ other_files)
          |> Enum.reject(&hidden_git_path?/1)
          |> Enum.map(&(prefix <> &1))

        roots = subtree_roots(dir, gitlinks, other_dirs)

        {subtree_files, failures} =
          Enum.reduce(roots, {[], []}, fn {rel, kind}, {files, fails} ->
            case descend(dir, rel, kind, prefix, seen, depth) do
              {:ok, f, fl} -> {files ++ f, fails ++ fl}
              {:error, reason} -> {files, fails ++ [{prefix <> rel, kind, reason}]}
            end
          end)

        {:ok, own, subtree_files, failures}
      end
    end
  end

  # Every path git collapses, from all three sources, de-duplicated:
  #
  #   * mode-160000 index entries — covers BOTH a declared submodule and an
  #     embedded independent repo that was `git add`ed (git records both as a
  #     gitlink; only `.gitmodules` tells them apart);
  #   * `--others` entries with a trailing slash — an embedded repo that was
  #     never committed. Git refuses to descend into it and emits the bare
  #     directory, so this is the ONLY signal it exists;
  #   * paths declared in `.gitmodules` (via `Topology.submodule_paths/1`, the
  #     shared classifier) that neither of the above reported — a submodule
  #     whose index entry is missing or whose path is gitignored would otherwise
  #     vanish without a trace.
  defp subtree_roots(dir, gitlinks, other_dirs) do
    declared = OptimalSystemAgent.Workspace.Topology.submodule_paths(dir)

    from_git =
      Enum.map(gitlinks, fn rel ->
        {rel, if(MapSet.member?(declared, rel), do: :submodule, else: :nested_repo)}
      end) ++ Enum.map(other_dirs, &{&1, :nested_repo})

    known = MapSet.new(from_git, fn {rel, _} -> rel end)

    extra =
      declared
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.filter(&File.dir?(Path.join(dir, &1)))
      |> Enum.map(&{&1, :submodule})

    (from_git ++ extra) |> Enum.uniq_by(fn {rel, _} -> rel end) |> Enum.sort()
  end

  defp descend(parent_dir, rel, _kind, prefix, seen, depth) do
    abs = Path.join(parent_dir, rel)
    child_prefix = prefix <> rel <> "/"

    cond do
      # A gitlink whose directory is gone, or an uninitialized submodule (an
      # empty placeholder directory). Both are faithfully mirrored as nothing —
      # there is no content to lose.
      not File.dir?(abs) or empty_dir?(abs) ->
        {:ok, [], []}

      # The normal case: it has its own git, so its own git enumerates it —
      # honoring its own .gitignore, and recursing into ITS submodules.
      File.exists?(Path.join(abs, ".git")) ->
        case collect(abs, child_prefix, seen, depth + 1) do
          {:ok, own, sub, fails} -> {:ok, own ++ sub, fails}
          {:error, reason} -> {:error, reason}
        end

      # Content on disk but no git to ask. Never shell `git ls-files` here: git
      # searches UPWARD, so it would silently answer for the parent repo.
      true ->
        fs_enumerate(parent_dir, abs, rel, child_prefix)
    end
  end

  # ── Non-git subtree fallback ───────────────────────────────────────────
  #
  # Filesystem walk with the same build/vendor exclusions the rest of OSA uses,
  # then one batched `git check-ignore` from the PARENT repo so its `.gitignore`
  # still governs. Deliberately not "copy everything on disk".

  @fs_skip_dirs MapSet.new(~w(
    .git .hg .svn .jj
    node_modules bower_components .bundle
    _build deps .elixir_ls .lexical
    target dist build out .next .nuxt .svelte-kit .turbo .parcel-cache
    .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache
    .terraform .terragrunt-cache .gradle .m2 .cargo .stack-work
    coverage .nyc_output .cache
  ))

  @max_fs_walk_files 200_000

  defp fs_enumerate(parent_dir, abs, rel, child_prefix) do
    case fs_walk(abs, "", []) do
      {:ok, rels} ->
        kept = reject_ignored(parent_dir, rel, rels)
        {:ok, Enum.map(kept, &(child_prefix <> &1)), []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fs_walk(dir, rel_prefix, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce_while(Enum.sort(entries), {:ok, acc}, fn entry, {:ok, acc} ->
          path = Path.join(dir, entry)
          rel = rel_prefix <> entry

          cond do
            length(acc) > @max_fs_walk_files ->
              {:halt, {:error, {:too_many_files, dir}}}

            MapSet.member?(@fs_skip_dirs, entry) ->
              {:cont, {:ok, acc}}

            symlink?(path) ->
              {:cont, {:ok, acc}}

            File.dir?(path) ->
              case fs_walk(path, rel <> "/", acc) do
                {:ok, acc} -> {:cont, {:ok, acc}}
                {:error, r} -> {:halt, {:error, r}}
              end

            true ->
              {:cont, {:ok, [rel | acc]}}
          end
        end)

      {:error, reason} ->
        {:error, {:ls, dir, reason}}
    end
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  # One `check-ignore` against the parent repo, batched over stdin-free argv in
  # chunks so a huge subtree cannot blow the argv limit. Exit 0 = some matched,
  # 1 = none, 128 = not a repo (in which case nothing is dropped).
  defp reject_ignored(parent_dir, rel, rels) do
    candidates = Enum.map(rels, &Path.join(rel, &1))

    ignored =
      candidates
      |> Enum.chunk_every(500)
      |> Enum.reduce(MapSet.new(), fn chunk, acc ->
        case OptimalSystemAgent.Git.cmd(["check-ignore", "-z", "--"] ++ chunk,
               cd: parent_dir,
               stderr_to_stdout: true
             ) do
          {out, 0} -> MapSet.union(acc, MapSet.new(String.split(out, <<0>>, trim: true)))
          _ -> acc
        end
      end)

    rels
    |> Enum.zip(candidates)
    |> Enum.reject(fn {_r, c} -> MapSet.member?(ignored, c) end)
    |> Enum.map(fn {r, _c} -> r end)
  rescue
    _ -> rels
  end

  # ── git plumbing ───────────────────────────────────────────────────────

  # `ls-files -z --stage` emits `<mode> <sha> <stage>\t<path>\0`. Mode 160000 is
  # a gitlink: the entry IS the collapsed subtree, not a file.
  defp tracked_entries(dir) do
    with {:ok, lines} <- git_paths(dir, ["ls-files", "-z", "--stage"]) do
      {files, links} =
        Enum.reduce(lines, {[], []}, fn line, {files, links} ->
          case String.split(line, "\t", parts: 2) do
            [meta, path] ->
              if String.starts_with?(meta, "160000"),
                do: {files, [path | links]},
                else: {[path | files], links}

            _ ->
              {files, links}
          end
        end)

      {:ok, Enum.reverse(files), Enum.reverse(links)}
    end
  end

  # `--others` recurses normal untracked directories but emits an embedded
  # repository as a bare `dir/` — it will not descend into another repo. The
  # trailing slash is therefore the marker for "a subtree git declined to list".
  defp untracked_entries(dir) do
    with {:ok, paths} <- git_paths(dir, ["ls-files", "-z", "--others", "--exclude-standard"]) do
      {dirs, files} = Enum.split_with(paths, &String.ends_with?(&1, "/"))
      {:ok, files, Enum.map(dirs, &String.trim_trailing(&1, "/"))}
    end
  end

  defp hidden_git_path?(path),
    do: path == "" or path == ".git" or String.starts_with?(path, ".git/")

  defp empty_dir?(path) do
    match?({:ok, []}, File.ls(path))
  end

  # Canonical identity for cycle detection. `Path.expand/1` is enough: a subtree
  # reached through a symlink is rejected before we ever recurse into it (see
  # `symlink?/1` in the filesystem walk), and gitlinks are never symlinks.
  defp real_path(path), do: Path.expand(path)

  # ── Copy-based tiers (reflink + plain) ─────────────────────────────────

  defp populate_copy(repo_dir, worktree_path, copy_fun, tier) do
    with {:ok, files} <- working_tree_files(repo_dir) do
      case copy_all(repo_dir, worktree_path, files, copy_fun) do
        {_ok, []} ->
          Logger.debug("[fast_worktree] #{tier} populated #{length(files)} files")
          finalize_index(worktree_path)
          :ok

        {_ok, [first | _] = errs} ->
          {:error, {:copy_failed, tier, length(errs), first}}
      end
    end
  end

  # Parallel copy of an already-enumerated list. Returns {copied, errors}.
  defp copy_all(src_root, dst_root, files, copy_fun) do
    files
    |> Task.async_stream(
      fn rel -> copy_one(src_root, dst_root, rel, copy_fun) end,
      max_concurrency: max_concurrency(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce({0, []}, fn
      {:ok, :ok}, {ok, errs} -> {ok + 1, errs}
      {:ok, {:error, e}}, {ok, errs} -> {ok, [e | errs]}
      {:exit, reason}, {ok, errs} -> {ok, [reason | errs]}
    end)
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
    _ =
      OptimalSystemAgent.Git.cmd(["read-tree", "HEAD"], cd: worktree_path, stderr_to_stdout: true)

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
