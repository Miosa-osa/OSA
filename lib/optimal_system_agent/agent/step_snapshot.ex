defmodule OptimalSystemAgent.Agent.StepSnapshot do
  @moduledoc """
  OpenCode-style filesystem snapshots of agent file steps.

  Complementary to `/rewind` (conversation checkpoints plus the shadow-git
  in `FSCheckpoint.Server`). This records the **user repo** worktree after a
  successful file-edit batch as hidden refs:

      refs/osa-step/<session_id>/<n>

  so the user's current branch is not littered with commits.

  Never pushes. Never runs `git commit` on the user's branch. Restore does
  not rewrite the conversation transcript (`updates.jsonl` stays).

  Git is injectable via `:git` `(cwd, args) -> {:ok, stdout} | {:error, reason}`,
  same seam as `OptimalSystemAgent.Security.CiScan`.
  """

  alias OptimalSystemAgent.Agent.Safety.PathCanon

  @table :osa_step_snapshots
  @ref_prefix "refs/osa-step"

  @type snapshot :: %{
          session_id: String.t(),
          n: pos_integer(),
          ref: String.t(),
          commit: String.t(),
          tree: String.t(),
          cwd: String.t(),
          paths: :all | [String.t()],
          recorded_at: DateTime.t()
        }

  @doc """
  Snapshot the worktree at `cwd` as the next step for `session_id`.

  Options:
    * `:git` - injectable `(cwd, args) -> {:ok, stdout} | {:error, reason}`
    * `:paths` - relative or absolute paths under `cwd` to include. When
      omitted, the whole worktree is snapshotted via a temporary index.
      Paths that escape `cwd` error. Never stages files outside `cwd`.
  """
  @spec record(String.t(), String.t(), keyword()) :: {:ok, snapshot()} | {:error, String.t()}
  def record(session_id, cwd, opts \\ [])

  def record(session_id, cwd, opts)
      when is_binary(session_id) and session_id != "" and is_binary(cwd) and is_list(opts) do
    ensure_table()

    with {:ok, cwd} <- expand_cwd(cwd),
         :ok <- require_dir(cwd),
         {:ok, pathspec} <- resolve_paths(cwd, opts),
         :ok <- require_git_repo(cwd, opts),
         :ok <- maybe_hydrate(session_id, Keyword.put(opts, :cwd, cwd)),
         {:ok, head} <- git_run(cwd, ["rev-parse", "HEAD"], opts) do
      n = next_n(session_id)
      parent = previous_commit(session_id) || head
      ref = ref_name(session_id, n)

      case write_snapshot(cwd, pathspec, parent, n, session_id, ref, opts) do
        {:ok, tree, commit} ->
          snap = %{
            session_id: session_id,
            n: n,
            ref: ref,
            commit: commit,
            tree: tree,
            cwd: cwd,
            paths: pathspec,
            recorded_at: DateTime.utc_now()
          }

          store_step(session_id, cwd, head, snap)
          {:ok, snap}

        {:error, _} = err ->
          err
      end
    end
  end

  def record(_session_id, _cwd, _opts), do: {:error, "session_id and cwd are required"}

  @doc """
  Restore the worktree to `n` steps back (1 = undo last snapshot).

  Transcript is never rewritten. Pass `:cwd` (defaults to the cwd stored on
  `record/3`). Pass `:git` to inject git.
  """
  @spec revert(String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def revert(session_id, n, opts \\ [])

  def revert(session_id, n, opts)
      when is_binary(session_id) and is_integer(n) and n > 0 and is_list(opts) do
    ensure_table()

    with :ok <- maybe_hydrate(session_id, opts),
         {:ok, rec} <- fetch_session(session_id),
         :ok <- require_recorded(rec, n),
         {:ok, cwd} <- revert_cwd(rec, opts),
         {:ok, cwd} <- expand_cwd(cwd),
         :ok <- require_dir(cwd),
         {:ok, target} <- target_snapshot(rec, n) do
      latest = List.last(rec.steps)

      with :ok <- restore_worktree(cwd, target.commit, latest.commit, opts) do
        {:ok,
         %{
           session_id: session_id,
           n: n,
           restored_n: target.n,
           ref: target.ref,
           commit: target.commit,
           paths: target.paths,
           transcript_rewritten: false
         }}
      end
    end
  end

  def revert(_session_id, n, _opts) when is_integer(n) and n <= 0 do
    {:error, "n must be a positive integer"}
  end

  def revert(_session_id, _n, _opts), do: {:error, "session_id is required"}

  @doc "Recorded snapshots for `session_id`, oldest first. Empty when none."
  @spec list(String.t()) :: [snapshot()]
  def list(session_id), do: list(session_id, [])

  @spec list(String.t(), keyword()) :: [snapshot()]
  def list(session_id, opts) when is_binary(session_id) and is_list(opts) do
    ensure_table()
    _ = maybe_hydrate(session_id, opts)

    case :ets.lookup(@table, session_id) do
      [{^session_id, %{steps: steps}}] -> steps
      _ -> []
    end
  end

  def list(_, _), do: []

  # ── Snapshot write (hidden ref, temp index) ───────────────────────────

  defp write_snapshot(cwd, pathspec, parent, n, session_id, ref, opts) do
    with_index(cwd, fn ->
      with {:ok, _} <- git_run(cwd, ["read-tree", parent], opts),
           {:ok, _} <- add_pathspec(cwd, pathspec, opts),
           {:ok, tree} <- git_run(cwd, ["write-tree"], opts),
           {:ok, commit} <-
             git_run(
               cwd,
               ["commit-tree", tree, "-p", parent, "-m", commit_message(n, session_id)],
               opts
             ),
           {:ok, _} <- git_run(cwd, ["update-ref", ref, commit], opts) do
        {:ok, tree, commit}
      end
    end)
  end

  defp add_pathspec(cwd, :all, opts), do: git_run(cwd, ["add", "-A"], opts)

  defp add_pathspec(cwd, paths, opts) when is_list(paths) do
    case paths do
      [] -> {:ok, ""}
      _ -> git_run(cwd, ["add", "-A", "--" | paths], opts)
    end
  end

  defp commit_message(n, session_id), do: "osa-step n=#{n} session=#{session_id}"

  defp with_index(_cwd, fun) do
    tmp = Path.join(System.tmp_dir!(), "osa-step-index-#{System.unique_integer([:positive])}")
    prev = Process.get(:osa_step_git_env)

    Process.put(:osa_step_git_env, [
      {"GIT_INDEX_FILE", tmp},
      {"GIT_AUTHOR_NAME", "OSA"},
      {"GIT_AUTHOR_EMAIL", "osa@local"},
      {"GIT_COMMITTER_NAME", "OSA"},
      {"GIT_COMMITTER_EMAIL", "osa@local"}
    ])

    try do
      fun.()
    after
      if prev, do: Process.put(:osa_step_git_env, prev), else: Process.delete(:osa_step_git_env)
      File.rm(tmp)
    end
  end

  # ── Restore ───────────────────────────────────────────────────────────

  defp restore_worktree(cwd, target_commit, latest_commit, opts) do
    with {:ok, _} <-
           git_run(cwd, ["restore", "--source=#{target_commit}", "--worktree", "--", "."], opts),
         {:ok, target_files} <- ls_tree(cwd, target_commit, opts),
         {:ok, latest_files} <- ls_tree(cwd, latest_commit, opts) do
      extras = MapSet.difference(MapSet.new(latest_files), MapSet.new(target_files))

      Enum.each(extras, fn rel ->
        case relative_inside(cwd, rel) do
          {:ok, safe} -> File.rm(Path.join(cwd, safe))
          {:error, _} -> :ok
        end
      end)

      :ok
    end
  end

  defp ls_tree(cwd, commit, opts) do
    case git_run(cwd, ["ls-tree", "-r", "--name-only", commit], opts) do
      {:ok, out} -> {:ok, String.split(out, ["\n", "\r\n"], trim: true)}
      {:error, _} = err -> err
    end
  end

  # ── Git repo / path guards ────────────────────────────────────────────

  defp require_dir(cwd) do
    if File.dir?(cwd), do: :ok, else: {:error, "cwd is required and must exist"}
  end

  # Path.expand does not resolve /var -> /private/var on macOS; PathCanon does.
  # Git `cd:` and the injectable `:git` fn must see the caller's path so tests
  # (and users) can match on the cwd they passed.
  defp expand_cwd(cwd) when is_binary(cwd) and cwd != "", do: {:ok, Path.expand(cwd)}
  defp expand_cwd(_), do: {:error, "cwd is required and must exist"}

  defp same_path?(a, b) do
    PathCanon.canonicalize(a) == PathCanon.canonicalize(b)
  end

  defp require_git_repo(cwd, opts) do
    case git_run(cwd, ["rev-parse", "--is-inside-work-tree"], opts) do
      {:ok, "true"} ->
        case git_run(cwd, ["rev-parse", "--show-toplevel"], opts) do
          {:ok, top} ->
            if same_path?(top, cwd) do
              :ok
            else
              {:error, "cwd must be the git work tree root"}
            end

          {:error, _} = err ->
            err
        end

      {:ok, _} ->
        {:error, "not a git repository"}

      {:error, reason} ->
        {:error, git_error(reason)}
    end
  end

  defp resolve_paths(cwd, opts) do
    case Keyword.get(opts, :paths) do
      nil ->
        {:ok, :all}

      paths when is_list(paths) ->
        Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
          case relative_inside(cwd, path) do
            {:ok, rel} -> {:cont, {:ok, acc ++ [rel]}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      _ ->
        {:error, "paths must be a list"}
    end
  end

  defp relative_inside(cwd, path) when is_binary(path) do
    cwd_c = PathCanon.canonicalize(cwd)
    abs = PathCanon.canonicalize(Path.expand(path, cwd))

    cond do
      abs == cwd_c ->
        {:ok, "."}

      String.starts_with?(abs, cwd_c <> "/") ->
        rel = Path.relative_to(abs, cwd_c)

        cond do
          rel in [".git", ""] ->
            {:error, "path escapes cwd"}

          String.starts_with?(rel, ".git/") ->
            {:error, "path escapes cwd"}

          String.starts_with?(rel, "..") ->
            {:error, "path escapes cwd"}

          Path.type(rel) == :absolute ->
            {:error, "path escapes cwd"}

          true ->
            {:ok, rel}
        end

      true ->
        {:error, "path escapes cwd"}
    end
  end

  defp relative_inside(_cwd, _path), do: {:error, "path escapes cwd"}

  # ── Session store ─────────────────────────────────────────────────────

  defp next_n(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, %{steps: steps}}] -> length(steps) + 1
      _ -> 1
    end
  end

  defp previous_commit(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, %{steps: steps}}] when steps != [] -> List.last(steps).commit
      _ -> nil
    end
  end

  defp store_step(session_id, cwd, base_commit, snap) do
    rec =
      case :ets.lookup(@table, session_id) do
        [{^session_id, existing}] ->
          %{existing | cwd: cwd, steps: existing.steps ++ [snap]}

        _ ->
          %{session_id: session_id, cwd: cwd, base_commit: base_commit, steps: [snap]}
      end

    :ets.insert(@table, {session_id, rec})
    :ok
  end

  defp fetch_session(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, rec}] -> {:ok, rec}
      _ -> {:error, "no steps recorded"}
    end
  end

  # Hidden refs survive a VM restart. ETS does not. Rebuild the in-memory
  # index from `refs/osa-step/<sid>/*` when the table has no row.
  defp maybe_hydrate(session_id, opts) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, _}] ->
        :ok

      _ ->
        case Keyword.get(opts, :cwd) do
          cwd when is_binary(cwd) and cwd != "" ->
            case expand_cwd(cwd) do
              {:ok, cwd} -> hydrate(session_id, cwd, opts)
              _ -> :ok
            end

          _ ->
            :ok
        end
    end
  end

  defp hydrate(session_id, cwd, opts) do
    prefix = "#{@ref_prefix}/#{safe_sid(session_id)}/"

    case git_run(cwd, ["for-each-ref", "--format=%(refname)|%(objectname)", prefix], opts) do
      {:ok, ""} ->
        :ok

      {:ok, out} ->
        steps =
          out
          |> String.split(["\n", "\r\n"], trim: true)
          |> Enum.map(&parse_ref_line(session_id, cwd, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.n)

        if steps == [] do
          :ok
        else
          base =
            case git_run(cwd, ["rev-parse", "#{hd(steps).commit}^"], opts) do
              {:ok, parent} -> parent
              _ -> nil
            end

          rec = %{session_id: session_id, cwd: cwd, base_commit: base, steps: steps}
          :ets.insert(@table, {session_id, rec})
          :ok
        end

      {:error, _} ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp parse_ref_line(session_id, cwd, line) do
    case String.split(line, "|", parts: 2) do
      [ref, commit] ->
        n =
          ref
          |> Path.basename()
          |> Integer.parse()
          |> case do
            {i, ""} when i >= 1 -> i
            _ -> nil
          end

        if is_integer(n) do
          %{
            session_id: session_id,
            n: n,
            ref: ref,
            commit: String.trim(commit),
            tree: "",
            cwd: cwd,
            paths: :all,
            recorded_at: DateTime.utc_now()
          }
        end

      _ ->
        nil
    end
  end

  defp require_recorded(%{steps: steps}, n) do
    count = length(steps)

    cond do
      count == 0 -> {:error, "no steps recorded"}
      n > count -> {:error, "only #{count} step(s) recorded"}
      true -> :ok
    end
  end

  # n=1 undoes the last snapshot (restores the previous recorded tree).
  # n equal to the recorded count restores the branch HEAD captured on
  # the first record (the tree before any snapshotted mutation).
  defp target_snapshot(%{steps: steps} = rec, n) do
    count = length(steps)
    idx = count - n - 1

    cond do
      idx >= 0 ->
        {:ok, Enum.at(steps, idx)}

      is_binary(rec[:base_commit]) and rec.base_commit != "" ->
        {:ok,
         %{
           n: 0,
           ref: "HEAD",
           commit: rec.base_commit,
           paths: :all
         }}

      true ->
        {:error, "only #{count} step(s) recorded"}
    end
  end

  defp revert_cwd(rec, opts) do
    case Keyword.get(opts, :cwd, rec.cwd) do
      cwd when is_binary(cwd) and cwd != "" -> {:ok, cwd}
      _ -> {:error, "cwd is required"}
    end
  end

  defp ref_name(session_id, n), do: "#{@ref_prefix}/#{safe_sid(session_id)}/#{n}"

  defp safe_sid(session_id) do
    sid =
      session_id
      |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
      |> String.trim("-")
      |> String.trim(".")

    if sid == "", do: "session", else: sid
  end

  # ── Git seam ──────────────────────────────────────────────────────────

  defp git_run(cwd, args, opts) do
    git_fn = Keyword.get(opts, :git, &default_git/2)

    case git_fn.(cwd, args) do
      {:ok, out} when is_binary(out) -> {:ok, String.trim_trailing(out)}
      {:error, reason} -> {:error, git_error(reason)}
      other -> {:error, "git failed: #{inspect(other)}"}
    end
  end

  defp default_git(cwd, args) do
    extra = Process.get(:osa_step_git_env, [])
    sys_opts = [cd: cwd, stderr_to_stdout: true]
    sys_opts = if extra == [], do: sys_opts, else: Keyword.put(sys_opts, :env, merge_env(extra))

    case OptimalSystemAgent.Git.cmd(args, sys_opts) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, "git exited #{status}: #{String.trim(out)}"}
    end
  rescue
    e in ErlangError ->
      case e do
        %ErlangError{original: :enoent} -> {:error, "git is not installed"}
        _ -> {:error, Exception.message(e)}
      end

    e ->
      {:error, Exception.message(e)}
  end

  defp merge_env(extra) do
    Enum.reduce(extra, Enum.to_list(System.get_env()), fn {k, v}, acc ->
      List.keystore(acc, k, 0, {k, v})
    end)
  end

  defp git_error(reason) when is_binary(reason) do
    if String.contains?(String.downcase(reason), "git"), do: reason, else: "git: #{reason}"
  end

  defp git_error(reason), do: "git failed: #{inspect(reason)}"

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end
end
