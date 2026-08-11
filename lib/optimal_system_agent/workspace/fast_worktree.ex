defmodule OptimalSystemAgent.Workspace.FastWorktree do
  @moduledoc """
  Copy-on-write isolated git worktrees for parallel sub-agents.

  An Elixir port of grok-build's `xai-fast-worktree`. Instead of a plain
  `git worktree add` that walks and checks out every tracked file (tens of
  seconds on a 100k-file repo), this creates a worktree whose files are
  populated by the fastest strategy the host filesystem supports, mirroring the
  source repo's *current working-tree state* (tracked + dirty + untracked-non-
  ignored), and finalizes the git index so `git status` is instant.

  ## Tier ladder (fastest → most portable)

  Mirrors grok's `Linked`/`Standalone` fast paths + `GitCheckout` fallback:

    1. `:btrfs`   — O(1) `btrfs subvolume snapshot` (btrfs subvolume repos only)
    2. `:reflink` — per-file `cp --reflink=always` CoW clone (XFS/btrfs)
    3. `:copy`    — parallel plain copy (works on **every** filesystem)
    4. `:git`     — plain `git worktree add` full checkout (ultimate fallback)

  `:overlayfs` is detected (`Capabilities`) but not used for population — a
  faithful overlay mount needs a FUSE-lower/btrfs-upper stack and CAP_SYS_ADMIN
  that a general deployment cannot assume; we fall through to a supported tier.

  The chosen tier is logged. On a plain ext4 box (no reflink/btrfs) the `:copy`
  tier carries the feature and is fully exercised.

  ## Crash recovery

  Every worktree writes a JSON sidecar (`Metadata`) carrying a per-VM boot
  token. `sweep/1` reclaims worktrees whose token is from a previous (crashed)
  run or whose directory has vanished — `git worktree remove` + `rm -rf` +
  deregister — so a killed OSA never leaks worktrees.

  ## Relationship to `Agent.Worktree`

  This module supersedes `Agent.Worktree.create/2` for the tiered creation +
  metadata + sweep. It reuses `Agent.Worktree`'s merge-back logic for the
  `merge: true` teardown path so the existing merge semantics are unchanged.
  The `enter_worktree`/`exit_worktree` LLM tools continue to use their own
  simple path and are untouched.
  """

  require Logger

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Workspace.Cwd
  alias OptimalSystemAgent.Workspace.FastWorktree.{Capabilities, Metadata, Populate}

  # Runtime-resolved default so a prebuilt release uses the END USER's home, not
  # the CI runner's baked-in path. The `:worktrees_dir` app-env override still
  # wins; only this fallback is resolved at call time.
  defp default_worktrees_dir, do: Path.join(ConfigFile.config_dir(), "worktrees")

  @type create_result :: %{
          path: String.t(),
          branch: String.t(),
          tier: atom(),
          repo_dir: String.t()
        }

  @doc """
  Managed directory that holds all fast worktrees. Overridable at runtime via
  `config :optimal_system_agent, :worktrees_dir, "..."` (used by tests to keep
  worktrees + sidecars out of the real `~/.osa`).
  """
  @spec worktrees_dir() :: String.t()
  def worktrees_dir do
    Application.get_env(:optimal_system_agent, :worktrees_dir) || default_worktrees_dir()
  end

  @doc """
  Detected filesystem capabilities for the repo backing `dir` (default: the
  agent cwd). Cached per device. See `Capabilities`.
  """
  @spec capabilities(String.t() | nil) :: Capabilities.t()
  def capabilities(dir \\ nil) do
    Capabilities.detect(dir || Cwd.get())
  end

  @doc """
  Create an isolated CoW worktree for `id`.

  Options:
    * `:repo_dir` — source repository (default: `Workspace.Cwd.get/0`, which
      resolves to the user's project — never the OSA source tree)
    * `:ref`      — git ref/commit-ish to base on (default: `"HEAD"`)
    * `:branch`   — branch name to create (default: generated, stable per id)
    * `:path`     — worktree directory (default: `<worktrees_dir>/<id>`)
    * `:prefer`   — explicit tier list override (e.g. `[:copy]`), mainly for tests

  Returns `{:ok, %{path, branch, tier, repo_dir}}` or `{:error, reason}`.
  Compatible superset of `Agent.Worktree.create/2`'s `%{path, branch}` shape.
  """
  @spec create(String.t(), keyword()) :: {:ok, create_result()} | {:error, term()}
  def create(id, opts \\ []) do
    repo_dir = Path.expand(opts[:repo_dir] || Cwd.get())
    ref = opts[:ref] || "HEAD"
    safe_id = sanitize(id)
    branch = opts[:branch] || "osa-wt-#{safe_id}-#{System.unique_integer([:positive])}"
    path = Path.expand(opts[:path] || Path.join(worktrees_dir(), safe_id))

    cond do
      not inside_git_repo?(repo_dir) ->
        {:error, "#{repo_dir} is not inside a git repository"}

      File.exists?(path) ->
        # Idempotency: reclaim a stale worktree left at this path.
        #
        # `path` is DETERMINISTIC per id, so "stale" is frequently not stale at
        # all: a retry, or a RESUME of the same subagent id, lands on the tree
        # the previous run left behind — uncommitted work and all. Removing it
        # unconditionally (rm -rf + `branch -D`) is unrecoverable. `reclaim/3`
        # captures a dirty tree in a durable ref first and only removes once
        # that ref actually persisted.
        case reclaim(path, repo_dir, opts) do
          :ok -> do_create(safe_id, branch, path, repo_dir, ref, opts)
          {:error, _} = err -> err
        end

      true ->
        do_create(safe_id, branch, path, repo_dir, ref, opts)
    end
  rescue
    e ->
      Logger.error("[fast_worktree] create crashed: #{Exception.message(e)}")
      {:error, "fast_worktree create error: #{Exception.message(e)}"}
  end

  defp do_create(safe_id, branch, path, repo_dir, ref, opts) do
    File.mkdir_p!(worktrees_dir())
    caps = capabilities(repo_dir)
    tiers = tier_order(caps, opts)

    case run_tiers(tiers, branch, path, repo_dir, ref, caps) do
      {:ok, tier} ->
        Logger.info(
          "[fast_worktree] created #{path} on #{branch} via #{tier} tier " <>
            "(fs=#{caps.fs_type})"
        )

        Metadata.write(worktrees_dir(), %{
          id: safe_id,
          path: path,
          branch: branch,
          repo_dir: repo_dir,
          tier: tier
        })

        emit_hook(:worktree_create, %{path: path, branch: branch, repo_dir: repo_dir, tier: tier})

        {:ok, %{path: path, branch: branch, tier: tier, repo_dir: repo_dir}}

      {:error, reason} ->
        Logger.error("[fast_worktree] all tiers failed for #{path}: #{inspect(reason)}")
        _ = fast_remove(path, repo_dir)
        {:error, "worktree creation failed: #{inspect(reason)}"}
    end
  end

  # Build the ordered tier list from capabilities. An explicit :prefer overrides
  # detection (tests / callers that want to force a tier). The plain `:git`
  # checkout is always appended as the guaranteed final fallback.
  defp tier_order(caps, opts) do
    base =
      case opts[:prefer] do
        list when is_list(list) and list != [] ->
          list

        _ ->
          [] ++
            if(caps.btrfs, do: [:btrfs], else: []) ++
            if(caps.reflink, do: [:reflink], else: []) ++
            [:copy]
      end

    Enum.uniq(base ++ [:git])
  end

  # Try each populate tier against a freshly-registered --no-checkout worktree.
  # `:git` is special — it does its own full-checkout `git worktree add`.
  defp run_tiers([], _branch, _path, _repo, _ref, _caps), do: {:error, :no_tiers}

  defp run_tiers([:git | _rest], branch, path, repo_dir, ref, _caps) do
    # Ultimate fallback: a full checkout. Clean HEAD (no dirty mirroring), but
    # guaranteed to work anywhere git does.
    #
    # A plain checkout has git's own blind spot: it leaves every gitlink path
    # (submodule, embedded independent repo) as an EMPTY directory. Filling
    # exactly those paths afterwards adds the missing components without
    # touching a single file the checkout wrote — see
    # `Populate.fill_hidden_subtrees/2`. A failure there is a real failure: this
    # is the last tier, so "succeed with the code missing" has no fallback left
    # to hide behind.
    ensure_absent(path, repo_dir)

    with {_out, 0} <- git(["worktree", "add", "-b", branch, path, ref], repo_dir),
         :ok <- Populate.fill_hidden_subtrees(repo_dir, path) do
      {:ok, :git}
    else
      {:error, reason} -> {:error, {:subtree_fill, reason}}
      {out, _} -> {:error, {:git_checkout, String.trim(out)}}
    end
  end

  defp run_tiers([tier | rest], branch, path, repo_dir, ref, caps) do
    ensure_absent(path, repo_dir)

    with {_out, 0} <-
           git(["worktree", "add", "--no-checkout", "-b", branch, path, ref], repo_dir),
         :ok <- Populate.run(tier, repo_dir, path, caps) do
      {:ok, tier}
    else
      :unsupported ->
        Logger.debug("[fast_worktree] tier #{tier} unsupported, falling through")
        run_tiers(rest, branch, path, repo_dir, ref, caps)

      # The source tree could not be fully enumerated. No other tier can
      # enumerate it either, so falling through would produce a worktree that
      # reports success while missing whole components — the exact silent
      # data-loss shape this guard exists to prevent. Abort instead.
      {:error, reason} ->
        if Populate.fatal?(reason) do
          Logger.error(
            "[fast_worktree] aborting: source tree could not be fully enumerated " <>
              "(#{inspect(reason)})"
          )

          {:error, reason}
        else
          Logger.warning(
            "[fast_worktree] tier #{tier} failed (#{inspect(reason)}), falling through"
          )

          run_tiers(rest, branch, path, repo_dir, ref, caps)
        end

      {out, _code} ->
        Logger.warning("[fast_worktree] worktree add failed for #{tier}: #{String.trim(out)}")
        run_tiers(rest, branch, path, repo_dir, ref, caps)
    end
  end

  @doc """
  Tear down a worktree. Honors the same options as `Agent.Worktree.cleanup/2`:

    * `merge: true`   — merge the branch back (delegates to `Agent.Worktree`),
      then remove.
    * `discard: true` — remove even a dirty worktree.
    * default         — a dirty worktree is preserved for parent review; a clean
      one is removed.

  Removal is the O(1)-ish path: `rm -rf` + `git worktree prune` + `branch -D`,
  which is dramatically faster than `git worktree remove` walking every file on
  a large tree. The sidecar is deleted once the directory is gone.
  """
  @spec teardown(String.t(), keyword()) :: :ok | {:error, term()}
  def teardown(path, opts \\ []) do
    path = Path.expand(path)
    repo_dir = Path.expand(opts[:repo_dir] || Cwd.get())
    merge = Keyword.get(opts, :merge, false)
    discard = Keyword.get(opts, :discard, false)
    has_changes = worktree_has_changes?(path)

    result =
      cond do
        merge and has_changes ->
          # Reuse the audited merge-back path, then ensure fast removal + prune.
          r = OptimalSystemAgent.Agent.Worktree.cleanup(path, merge: true, repo_dir: repo_dir)
          _ = fast_remove(path, repo_dir)
          r

        has_changes and not discard ->
          Logger.info("[fast_worktree] preserving dirty worktree #{path} for review")
          :ok

        true ->
          fast_remove(path, repo_dir)
      end

    unless File.dir?(path), do: Metadata.delete_by_path(worktrees_dir(), path)

    emit_hook(:worktree_remove, %{
      path: path,
      had_changes: has_changes,
      merged: merge and has_changes,
      preserved: has_changes and not merge and not discard
    })

    result
  end

  @doc """
  P8 — snapshot a worktree's CURRENT state into a durable git ref, so it stays
  inspectable/resumable after `teardown/2` merges (folds into a real branch)
  or discards (deletes) the worktree. This is the middle ground between the
  two: the work is neither merged into the parent branch nor lost.

  Any uncommitted changes (tracked + untracked-non-ignored) are committed to
  the worktree's own branch first, so the ref captures the FULL working-tree
  state the child left behind, not just its last real commit. That commit is
  local to the worktree's branch — it is never merged/rebased onto the
  caller's branch. The worktree's branch objects live in the shared object
  database, so the ref remains resolvable (`git show <ref>`, `git worktree add
  -b tmp <ref>`) from the main repo even after the worktree directory and its
  branch ref are removed by `teardown/2`.

  Options:
    * `:repo_dir` — the source repository the ref is written into (default:
      `Workspace.Cwd.get/0`)
    * `:id`       — stable identifier used in the ref name (default: the
      worktree's basename)
    * `:ref_prefix` — override the ref namespace (default: `refs/osa/subagent-snapshots`,
      or `config :optimal_system_agent, :subagent_worktree_snapshot_ref_prefix`)

  Returns `{:ok, ref}` (e.g. `"refs/osa/subagent-snapshots/agent-42-1700000000"`)
  or `{:error, reason}`. Never raises — a snapshot failure should never fail a
  teardown.
  """
  @spec snapshot_ref(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def snapshot_ref(path, opts \\ []) do
    path = Path.expand(path)
    repo_dir = Path.expand(opts[:repo_dir] || Cwd.get())
    id = sanitize(opts[:id] || Path.basename(path))
    prefix = opts[:ref_prefix] || snapshot_ref_prefix()
    ref = "#{prefix}/#{id}-#{System.system_time(:second)}"

    cond do
      not File.dir?(path) ->
        {:error, :worktree_missing}

      not inside_git_repo?(repo_dir) ->
        {:error, "#{repo_dir} is not inside a git repository"}

      true ->
        do_snapshot_ref(path, repo_dir, ref)
    end
  rescue
    e ->
      Logger.error("[fast_worktree] snapshot_ref crashed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp do_snapshot_ref(path, repo_dir, ref) do
    if worktree_has_changes?(path) do
      _ = git(["add", "-A"], path)
      _ = git(["commit", "--no-verify", "-m", "osa: subagent worktree snapshot"], path)
    end

    with sha when is_binary(sha) and sha != "" <- current_sha(path),
         {_out, 0} <- git(["update-ref", ref, sha], repo_dir) do
      Logger.info("[fast_worktree] snapshot ref #{ref} -> #{sha}")
      {:ok, ref}
    else
      {out, _code} -> {:error, {:update_ref_failed, String.trim(out)}}
      _ -> {:error, :no_commit}
    end
  end

  @default_snapshot_ref_prefix "refs/osa/subagent-snapshots"

  defp snapshot_ref_prefix do
    Application.get_env(
      :optimal_system_agent,
      :subagent_worktree_snapshot_ref_prefix,
      @default_snapshot_ref_prefix
    )
  end

  defp current_sha(path) do
    case git(["rev-parse", "HEAD"], path) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  @doc """
  Crash-recovery sweep. Reclaims orphaned worktrees.

  A worktree is an orphan when (default `stale_only: true`):
    * its sidecar's boot token differs from the current VM's (created by a
      previous, likely crashed, run), or
    * its directory has vanished (dangling sidecar / half-removed).

  With `stale_only: false`, **all** managed worktrees are reclaimed (hard reset).
  Returns `{:ok, %{removed: [path], kept: [path]}}`.

  ## Dirty worktrees are never swept

  "Orphan" here means *a previous VM booted this sidecar*, which is NOT the same
  as *nobody wants this tree*. `teardown/2` deliberately PRESERVES a dirty
  worktree so the parent can review or apply it, and those preserved trees keep
  their sidecar — so an unguarded sweep would delete exactly the work teardown
  went out of its way to save. A worktree with uncommitted changes is therefore
  reported in `kept` and left on disk, whatever `stale_only` says. Pass
  `force: true` for the true hard reset that removes dirty trees too.

  This function has no caller in `lib/` today; the gate exists so wiring it up
  later cannot silently destroy uncommitted work.
  """
  @spec sweep(keyword()) :: {:ok, %{removed: [String.t()], kept: [String.t()]}}
  def sweep(opts \\ []) do
    stale_only = Keyword.get(opts, :stale_only, true)
    force = Keyword.get(opts, :force, false)
    current = Metadata.boot_token()
    default_repo = Path.expand(opts[:repo_dir] || Cwd.get())

    {removed, kept} =
      worktrees_dir()
      |> Metadata.list()
      |> Enum.reduce({[], []}, fn rec, {rm, kp} ->
        wt_path = rec["path"]

        orphan? =
          cond do
            not stale_only -> true
            rec["boot_token"] != current -> true
            is_binary(wt_path) and not File.dir?(wt_path) -> true
            true -> false
          end

        dirty? =
          is_binary(wt_path) and File.dir?(wt_path) and worktree_has_changes?(wt_path)

        cond do
          orphan? and dirty? and not force ->
            Logger.warning(
              "[fast_worktree] sweep: keeping orphan worktree #{wt_path} — it has " <>
                "uncommitted changes (pass force: true to remove anyway)"
            )

            {rm, [wt_path | kp]}

          orphan? ->
            repo = rec["repo_dir"] || default_repo
            if is_binary(wt_path), do: fast_remove(wt_path, repo, rec["branch"])
            Metadata.delete(worktrees_dir(), rec["id"])
            Logger.info("[fast_worktree] swept orphan worktree #{wt_path}")
            {[wt_path | rm], kp}

          true ->
            {rm, [wt_path | kp]}
        end
      end)

    {:ok, %{removed: Enum.reverse(removed), kept: Enum.reverse(kept)}}
  end

  @doc "List active worktrees tracked by sidecar metadata."
  @spec list() :: [map()]
  def list do
    worktrees_dir()
    |> Metadata.list()
    |> Enum.map(fn r ->
      %{path: r["path"], branch: r["branch"], tier: r["tier"], repo_dir: r["repo_dir"]}
    end)
  end

  # ── Private ────────────────────────────────────────────────────────────

  # Reclaim a worktree directory already sitting at the deterministic path.
  #
  # A CLEAN tree has nothing to lose and is removed directly. A DIRTY tree is
  # snapshotted into a durable ref FIRST, and only a ref that actually persisted
  # licenses the removal — the same gate grok applies via
  # `update_subagent_meta_snapshot_ref`'s boolean return. When the snapshot
  # cannot be written, creation FAILS rather than destroying uncommitted work;
  # the caller falls back to running without isolation, which is recoverable.
  #
  # `reclaim: :force` opts out for callers that genuinely mean "nuke it".
  defp reclaim(path, repo_dir, opts) do
    cond do
      opts[:reclaim] == :force ->
        _ = fast_remove(path, repo_dir)
        :ok

      not worktree_has_changes?(path) ->
        _ = fast_remove(path, repo_dir)
        :ok

      true ->
        case snapshot_ref(path, repo_dir: repo_dir, id: Path.basename(path)) do
          {:ok, ref} ->
            Logger.warning(
              "[fast_worktree] reclaiming dirty worktree #{path} — uncommitted state " <>
                "preserved at #{ref}"
            )

            _ = fast_remove(path, repo_dir)
            :ok

          {:error, reason} ->
            Logger.error(
              "[fast_worktree] refusing to reclaim dirty worktree #{path}: snapshot failed " <>
                "(#{inspect(reason)}) — uncommitted work would be lost"
            )

            {:error, {:dirty_worktree_not_snapshotted, path, reason}}
        end
    end
  end

  # O(1)-ish removal: bulk rm then deregister, instead of git worktree remove
  # walking every file. Reads the branch first (needs the worktree to exist);
  # a caller that already knows the branch (e.g. the sweep, from the sidecar)
  # can pass it so a vanished-dir worktree still gets its branch cleaned up.
  defp fast_remove(path, repo_dir, branch \\ nil) do
    branch = branch || current_branch(path)
    _ = File.rm_rf(path)
    _ = git(["worktree", "prune"], repo_dir)
    if is_binary(branch) and branch != "", do: git(["branch", "-D", branch], repo_dir)
    :ok
  rescue
    _ -> :ok
  end

  # Ensure `path` is not registered/present before a fresh `git worktree add`.
  defp ensure_absent(path, repo_dir) do
    if File.exists?(path), do: fast_remove(path, repo_dir)
    _ = git(["worktree", "prune"], repo_dir)
    :ok
  end

  defp current_branch(path) do
    # Guard on existence: System.cmd with a `cd:` into a vanished dir prints a
    # noisy `spawn: Could not cd` to stderr. A vanished worktree has no
    # recoverable branch anyway.
    if File.dir?(path) do
      case git(["branch", "--show-current"], path) do
        {out, 0} -> String.trim(out)
        _ -> nil
      end
    else
      nil
    end
  end

  defp worktree_has_changes?(path) do
    case git(["status", "--porcelain"], path) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  defp inside_git_repo?(dir) do
    match?({_, 0}, git(["rev-parse", "--git-dir"], dir))
  end

  defp git(args, cd) do
    OptimalSystemAgent.Git.cmd(args, cd: cd, stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), 1}
  end

  defp sanitize(id), do: Regex.replace(~r/[^a-zA-Z0-9_\-]/, to_string(id), "_")

  defp emit_hook(event, payload) do
    OptimalSystemAgent.Agent.Hooks.run_async(event, payload)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
