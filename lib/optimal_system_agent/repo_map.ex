defmodule OptimalSystemAgent.RepoMap do
  @moduledoc """
  A live, per-workspace model of the repo OSA is working in: file tree,
  key symbols per file, the last test run's status, and git checkout
  identity — the map a good regulator needs of what it regulates (Conant &
  Ashby), kept cheap by never being rebuilt from scratch on the model's
  behalf.

  ## Why

  Without this, "what does this file define" and "which checkout am I even
  in" are answered by re-grepping and re-`git status`-ing from zero on every
  turn that needs them — expensive, and worse, silently WRONG when nobody
  bothers to check: an operator's agent once grepped a stale checkout 122
  commits behind the installed release and drew conclusions from it. A model
  is exactly one `repo_map` tool call away from an answer that is honest
  about which commit it is looking at.

  ## What is cached, and how it stays fresh

  The model is built ONCE per workspace root (a single `git ls-files` call
  plus a `GitState.refresh/1`) and cached in ETS, keyed by the expanded root
  path — same shape as `Workspace.Topology`'s cache, deliberately: this is
  never rescanned on the model's behalf mid-turn.

  It is kept current two ways, neither of which is "rewalk everything":

    * **Tool results** — `observe_tool_result/4` is a cheap, best-effort hook
      called after a tool finishes (see `Agent.Loop.ToolExecutor`). A write
      tool touches exactly the file(s) it wrote (re-stats it, re-extracts its
      symbols); a shell command that looks like a test run updates
      `RepoMap.TestStatus`; a git-mutating command refreshes
      `RepoMap.GitState`.
    * **A background watcher** (`RepoMap.Watcher`) — polls on its own timer,
      independent of turn cadence, and diffs `git status` against what it
      last saw so an edit made OUTSIDE OSA (another terminal, an editor, a
      build step) is not invisible until the model happens to touch that file
      itself.

  ## Symbols are lazy, not precomputed

  Building `files` populates paths, not their symbols — extracting every
  file's symbols eagerly does not scale to a large repo. `symbols_for_file/3`
  computes and caches a file's symbols the first time anything asks for them
  (via `CodeSymbols.Handler.symbols_for/2`, the SAME per-language extractor
  the `code_symbols` tool uses), and `observe_tool_result/4` refreshes just
  the touched file's entry when a write tool changes it.
  """

  require Logger

  alias OptimalSystemAgent.Git
  alias OptimalSystemAgent.RepoMap.GitState
  alias OptimalSystemAgent.RepoMap.TestStatus
  alias OptimalSystemAgent.Tools.Builtins.CodeSymbols.Handler, as: SymbolHandler

  @table :osa_repo_map

  @type file_entry :: %{size: non_neg_integer(), mtime: integer(), symbols: [tuple()] | nil}
  @type t :: %{
          root: String.t(),
          built_at: integer(),
          updated_at: integer(),
          files: %{String.t() => file_entry()},
          file_count: non_neg_integer(),
          truncated: boolean(),
          git: GitState.t() | nil,
          tests: TestStatus.t() | nil
        }

  @max_files 20_000
  @max_walk_files 5_000

  @excluded_segments MapSet.new(~w(
    .git _build deps node_modules target dist build .next .nuxt .svelte-kit
    .venv venv __pycache__ .mypy_cache .pytest_cache .elixir_ls .lexical
    .terraform .gradle .cargo .stack-work coverage .cache tmp temp log logs
  ))

  # Write-shaped tools whose args name the file(s) they just changed.
  @write_tools ~w(file_write file_edit structural_edit multi_file_edit notebook_edit file_transform rollback)
  @shell_tools ~w(shell_execute bash_output pty_send)

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  The cached model for `root`, building it on first access. Pass
  `refresh: true` to force a full rebuild (file tree + git state).

  Never call this with `refresh: true` from a per-turn hot path — see the
  moduledoc. `observe_tool_result/4` and `RepoMap.Watcher` are how it stays
  current without a full rebuild.
  """
  @spec get(String.t(), keyword()) :: t()
  def get(root, opts \\ []) do
    root = Path.expand(root)
    ensure_table()

    if opts[:refresh] do
      recompute(root, opts)
    else
      case :ets.lookup(@table, root) do
        [{^root, model}] -> model
        [] -> recompute(root, opts)
      end
    end
  rescue
    e ->
      Logger.debug("[repo_map] get failed for #{root}: #{Exception.message(e)}")
      empty(root)
  end

  @doc "Force a full rebuild for `root`. Equivalent to `get(root, refresh: true)`."
  @spec refresh(String.t(), keyword()) :: t()
  def refresh(root, opts \\ []), do: get(root, Keyword.put(opts, :refresh, true))

  @doc "Drop the cached model for `root` (or every root when `:all`)."
  @spec invalidate(String.t() | :all) :: :ok
  def invalidate(:all) do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  end

  def invalidate(root) when is_binary(root) do
    ensure_table()
    :ets.delete(@table, Path.expand(root))
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Whether `root` already has a cached model — the check `RepoMap.Watcher`
  uses so its poll tick never builds a model for a workspace nobody has
  actually consulted yet.
  """
  @spec cached?(String.t()) :: boolean()
  def cached?(root) do
    ensure_table()
    :ets.member(@table, Path.expand(root))
  rescue
    _ -> false
  end

  @doc """
  Incrementally sync FROM a fresh `git status`, without a full file-tree
  rewalk: refreshes `git_state/2`, then re-stats/re-extracts symbols for
  exactly the files git reports as changed (or drops them, if deleted).

  This is `RepoMap.Watcher`'s poll-tick primitive — a single cheap
  `git status` diff is enough to catch an edit made OUTSIDE OSA (another
  terminal, an editor, a build step) without rescanning the whole tree. A
  safe no-op when `root` has no cached model yet.
  """
  @spec sync_from_git(String.t()) :: :ok
  def sync_from_git(root) do
    root = Path.expand(root)
    ensure_table()

    case :ets.lookup(@table, root) do
      [{^root, model}] ->
        new_git = GitState.refresh(root)
        changed = dirty_relpaths(new_git)
        files = Enum.reduce(changed, model.files, &touch_one(root, &1, &2))

        updated = %{
          model
          | git: new_git,
            files: files,
            file_count: map_size(files),
            updated_at: now_ms()
        }

        :ets.insert(@table, {root, updated})
        :ok

      [] ->
        :ok
    end
  rescue
    e ->
      Logger.debug("[repo_map] sync_from_git failed for #{root}: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Symbols for one file, computing and caching them on first request.

  Reuses `CodeSymbols.Handler.symbols_for/2` — the same per-language
  extractor the `code_symbols` tool uses — so this is not a second
  implementation of "what does this file define".
  """
  @spec symbols_for_file(String.t(), String.t(), keyword()) ::
          {:ok, [tuple()]} | {:error, String.t()}
  def symbols_for_file(root, rel_path, opts \\ []) do
    root = Path.expand(root)
    model = get(root, opts)

    case Map.get(model.files, rel_path) do
      %{symbols: symbols} when is_list(symbols) ->
        {:ok, symbols}

      entry when not is_nil(entry) ->
        compute_and_cache_symbols(root, rel_path)

      nil ->
        {:error,
         "#{rel_path} is not in the repo map for #{root}. If it was just created, call " <>
           "repo_map with refresh: true."}
    end
  end

  @doc "The last known git checkout state for `root` (or `nil` outside a repo)."
  @spec git_state(String.t(), keyword()) :: GitState.t() | nil
  def git_state(root, opts \\ []), do: get(root, opts).git

  @doc "The last observed test-run status for `root` (or `nil` if none yet)."
  @spec test_status(String.t(), keyword()) :: TestStatus.t() | nil
  def test_status(root, opts \\ []), do: get(root, opts).tests

  @doc """
  A one-line, cheap-to-read summary — file count, checkout identity, last
  test status — for wherever "a compact summary in context" pays off.
  """
  @spec summary(String.t(), keyword()) :: String.t()
  def summary(root, opts \\ []) do
    model = get(root, opts)

    truncated_note = if model.truncated, do: " (truncated)", else: ""

    "#{model.file_count} files tracked#{truncated_note} · #{git_summary(model.git)}" <>
      test_summary(model.tests)
  end

  @doc """
  Best-effort update from ONE tool call's result. Called by
  `Agent.Loop.ToolExecutor` after a tool finishes; never raises, never forces
  a rebuild — it only touches an existing cached model, so calling this
  before anything has ever called `get/2` for `root` is a safe no-op.
  """
  @spec observe_tool_result(String.t(), String.t(), map(), String.t()) :: :ok
  def observe_tool_result(root, tool_name, args, result_str)
      when is_binary(root) and is_binary(tool_name) and is_map(args) and is_binary(result_str) do
    root = Path.expand(root)

    cond do
      tool_name in @write_tools ->
        touch_files(root, extract_paths(args))

      tool_name in @shell_tools ->
        observe_shell(root, args, result_str)

      tool_name == "git" ->
        refresh_git(root)

      true ->
        :ok
    end

    :ok
  rescue
    e ->
      Logger.debug("[repo_map] observe_tool_result failed: #{Exception.message(e)}")
      :ok
  end

  def observe_tool_result(_root, _tool_name, _args, _result_str), do: :ok

  # ── Build ────────────────────────────────────────────────────────────

  defp recompute(root, opts) do
    model = build(root, opts)
    ensure_table()
    :ets.insert(@table, {root, model})
    model
  end

  defp build(root, opts) do
    {rel_paths, truncated} = list_files(root, opts)

    files =
      Map.new(rel_paths, fn rel -> {rel, %{size: nil, mtime: nil, symbols: nil}} end)

    %{
      root: root,
      built_at: System.monotonic_time(:millisecond),
      updated_at: System.monotonic_time(:millisecond),
      files: files,
      file_count: map_size(files),
      truncated: truncated,
      git: GitState.refresh(root),
      tests: nil
    }
  end

  defp list_files(root, opts) do
    max = Keyword.get(opts, :max_files, @max_files)

    files =
      case git_ls_files(root) do
        {:ok, files} -> files
        :error -> walk_files(root)
      end

    filtered = Enum.reject(files, &excluded?/1)

    if length(filtered) > max do
      {Enum.take(filtered, max), true}
    else
      {filtered, false}
    end
  end

  defp excluded?(rel) do
    rel |> Path.split() |> Enum.any?(&MapSet.member?(@excluded_segments, &1))
  end

  defp git_ls_files(root) do
    case Git.cmd(["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, out |> String.split(<<0>>, trim: true)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp walk_files(root) do
    {files, _count} = do_walk(root, root, [], 0)
    files
  end

  defp do_walk(_root, _dir, acc, count) when count >= @max_walk_files, do: {acc, count}

  defp do_walk(root, dir, acc, count) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {acc, count}, fn entry, {acc2, count2} ->
          if count2 >= @max_walk_files do
            {:halt, {acc2, count2}}
          else
            path = Path.join(dir, entry)

            cond do
              String.starts_with?(entry, ".") ->
                {:cont, {acc2, count2}}

              MapSet.member?(@excluded_segments, entry) ->
                {:cont, {acc2, count2}}

              File.dir?(path) and not symlink?(path) ->
                {acc3, count3} = do_walk(root, path, acc2, count2)
                {:cont, {acc3, count3}}

              File.regular?(path) ->
                {:cont, {[Path.relative_to(path, root) | acc2], count2 + 1}}

              true ->
                {:cont, {acc2, count2}}
            end
          end
        end)

      _ ->
        {acc, count}
    end
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  # ── Incremental updates ────────────────────────────────────────────────

  defp touch_files(_root, []), do: :ok

  defp touch_files(root, paths) do
    with_model(root, fn model ->
      files =
        Enum.reduce(paths, model.files, fn path, acc ->
          rel = to_relative(root, path)
          touch_one(root, rel, acc)
        end)

      %{model | files: files, file_count: map_size(files), updated_at: now_ms()}
    end)
  end

  defp touch_one(root, rel, files) do
    abs = Path.join(root, rel)

    case File.stat(abs) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        symbols = safe_symbols(abs)
        Map.put(files, rel, %{size: size, mtime: mtime, symbols: symbols})

      _ ->
        # File no longer exists (a delete/rollback) — drop it from the tree
        # instead of leaving a stale, now-unreadable entry behind.
        Map.delete(files, rel)
    end
  end

  # Relative paths named by a fresh `git status --porcelain=v1` snapshot —
  # `GitState.dirty_files/1`'s lines, positionally parsed. Porcelain v1 is
  # fixed-width: 2 status columns, then ONE separator space, then the path —
  # so this slices by position rather than splitting on the first space,
  # which would corrupt a path when a status column is itself a space (e.g.
  # " M path", worktree-only modification).
  defp dirty_relpaths(nil), do: []
  defp dirty_relpaths(%{dirty_files: lines}), do: Enum.map(lines, &porcelain_path/1)

  defp porcelain_path(line) do
    path_part = if String.length(line) > 3, do: String.slice(line, 3..-1//1), else: ""

    # A rename/copy line is "old -> new"; the NEW path is the one that
    # exists on disk now and needs (re-)stating.
    case String.split(path_part, " -> ") do
      [_old, new_path] -> new_path
      [only] -> only
    end
  end

  defp compute_and_cache_symbols(root, rel_path) do
    abs = Path.join(root, rel_path)

    case File.read(abs) do
      {:ok, content} ->
        ext = abs |> Path.extname() |> String.downcase()
        symbols = SymbolHandler.symbols_for(content, ext)

        with_model(root, fn model ->
          case Map.get(model.files, rel_path) do
            nil ->
              model

            entry ->
              %{model | files: Map.put(model.files, rel_path, %{entry | symbols: symbols})}
          end
        end)

        {:ok, symbols}

      {:error, reason} ->
        {:error, "Could not read #{rel_path}: #{inspect(reason)}"}
    end
  end

  defp safe_symbols(abs) do
    case File.read(abs) do
      {:ok, content} ->
        SymbolHandler.symbols_for(content, abs |> Path.extname() |> String.downcase())

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp observe_shell(root, args, result_str) do
    command = shell_command(args)

    case TestStatus.parse(command, result_str) do
      {:ok, status} -> put_tests(root, status)
      :not_a_test_run -> :ok
    end

    if git_mutating_command?(command), do: refresh_git(root)
  end

  defp shell_command(args) do
    Map.get(args, "command") || Map.get(args, "cmd") || Map.get(args, :command)
  end

  @git_mutating_re ~r/\bgit\s+(commit|checkout|merge|rebase|pull|push|reset|stash|branch|switch|cherry-pick|revert)\b/

  defp git_mutating_command?(command) when is_binary(command),
    do: Regex.match?(@git_mutating_re, command)

  defp git_mutating_command?(_), do: false

  defp put_tests(root, status) do
    with_model(root, fn model -> %{model | tests: status, updated_at: now_ms()} end)
  end

  defp refresh_git(root) do
    with_model(root, fn model -> %{model | git: GitState.refresh(root), updated_at: now_ms()} end)
  end

  # Applies `fun` to the cached model for `root`, IF one exists. Never
  # builds a model that doesn't already exist — an update from a tool call
  # is not itself justification for the first, real `get/2` walk.
  defp with_model(root, fun) do
    ensure_table()

    case :ets.lookup(@table, root) do
      [{^root, model}] ->
        :ets.insert(@table, {root, fun.(model)})
        :ok

      [] ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp extract_paths(args) do
    cond do
      is_binary(Map.get(args, "path")) -> [args["path"]]
      is_list(Map.get(args, "paths")) -> Enum.filter(args["paths"], &is_binary/1)
      is_binary(Map.get(args, "file_path")) -> [args["file_path"]]
      true -> []
    end
  end

  defp to_relative(root, path) do
    expanded = Path.expand(path, root)

    if String.starts_with?(expanded, root <> "/") do
      Path.relative_to(expanded, root)
    else
      # Outside root, or already relative in a way `Path.expand` can't
      # anchor usefully — store it as given rather than guess.
      path
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ── Summary formatting ─────────────────────────────────────────────────

  defp git_summary(nil), do: "git: unavailable"

  defp git_summary(git) do
    dirty = if git.dirty_count > 0, do: "#{git.dirty_count} dirty", else: "clean"
    "#{git.branch}@#{git.head_sha_short || "?"} (#{dirty}#{ahead_behind_note(git)})"
  end

  defp ahead_behind_note(%{ahead: a, behind: b})
       when is_integer(a) and is_integer(b) and (a > 0 or b > 0) do
    ", +#{a}/-#{b} vs upstream"
  end

  defp ahead_behind_note(_), do: ""

  defp test_summary(nil), do: ""
  defp test_summary(%{status: :passed} = t), do: " · tests: passed (#{t.summary})"
  defp test_summary(%{status: :failed} = t), do: " · tests: FAILED (#{t.summary})"

  defp test_summary(%{status: :unknown, tool: tool}),
    do: " · tests: ran (#{tool}, unrecognized output)"

  # ── ETS ──────────────────────────────────────────────────────────────

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _ -> @table
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp empty(root) do
    %{
      root: root,
      built_at: now_ms(),
      updated_at: now_ms(),
      files: %{},
      file_count: 0,
      truncated: false,
      git: nil,
      tests: nil
    }
  end
end
