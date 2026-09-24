defmodule OptimalSystemAgent.Prefetch.Heuristics do
  @moduledoc """
  Pure candidate-generation for speculative prefetch.

  Every function here only reads the filesystem to decide whether a guess is
  worth firing (`File.regular?/1`, `File.ls/1`) — it never opens or executes
  anything. `Prefetch.Engine` is the one place a candidate this module returns
  actually runs.

  A "candidate" is `%{tool: tool_name, args: args, watch: watch}` — `watch` is
  whatever `Prefetch.Cache.path_watch/1` returns, threaded straight through so
  the engine never has to re-derive it.

  ## Why there is no `git status`/`git diff` candidate

  Every OTHER candidate here watches a single file, so `Prefetch.Cache` can
  cheaply prove staleness with one `File.stat/1` before serving a hit. A `git
  status`/`git diff` result depends on the ENTIRE working tree plus the
  index and HEAD — proving it is still valid would mean stat-ing every
  tracked file, which costs as much as the git call itself and defeats the
  point of caching it. Rather than ship a validator that LOOKS cheap and
  reliable but is not, this heuristic set does not generate git candidates at
  all.
  """

  alias OptimalSystemAgent.Prefetch.Cache
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.ReadOnly

  # Best-effort, bounded: a wrong guess costs one skipped disk read, but an
  # unbounded one costs CPU/IO the model never asked for.
  @max_text_candidates 6
  @max_sibling_candidates 4

  # A path-looking token: at least one directory separator OR a leading `./`,
  # ending in a recognised source-file extension. Deliberately narrow — this
  # runs against every streamed delta, so false positives (a URL, a version
  # number, a stray "e.g. foo.bar") are worse than a missed candidate; the
  # model's own next tool call is the fallback for anything this misses.
  @path_regex ~r"""
    (?:^|[\s"'`(\[,])
    (
      (?:\.{1,2}/|/|[A-Za-z0-9_.\-]+/)
      [A-Za-z0-9_.\-/]*
      \.(?:ex|exs|erl|hrl|rs|py|js|jsx|ts|tsx|go|rb|java|kt|c|h|cc|cpp|hpp|
         css|scss|html|json|toml|yaml|yml|md|sql|sh|lock|proto|graphql)
    )
    (?=[\s"'`)\]:,.;!?]|$)
  """x

  @doc """
  File-read candidates for paths named in the model's streamed text so far.

  `cwd` resolves a relative-looking match; only matches that resolve to a real
  regular file survive — everything else is silently dropped (this is a hint,
  not a claim).
  """
  @spec candidates_from_text(String.t(), String.t()) :: [map()]
  def candidates_from_text(text, cwd) when is_binary(text) and is_binary(cwd) do
    @path_regex
    |> Regex.scan(text)
    |> Enum.map(fn [_, captured] -> captured end)
    |> Enum.uniq()
    |> Enum.map(&Path.expand(&1, cwd))
    |> Enum.filter(&File.regular?/1)
    |> Enum.take(@max_text_candidates)
    |> Enum.map(&file_read_candidate/1)
  end

  def candidates_from_text(_text, _cwd), do: []

  @doc """
  File-read candidates for the siblings of a just-edited file — the next
  files a "read the module, edit it, now check its neighbours" pass tends to
  want. Alphabetical, capped, existing regular files only.
  """
  @spec sibling_candidates(String.t()) :: [map()]
  def sibling_candidates(edited_path) when is_binary(edited_path) do
    dir = Path.dirname(edited_path)
    base = Path.basename(edited_path)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == base or hidden?(&1)))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.take(@max_sibling_candidates)
        |> Enum.map(&file_read_candidate/1)

      _ ->
        []
    end
  end

  def sibling_candidates(_), do: []

  @doc """
  File-read candidate(s) for the test file of an edited lib module, or the lib
  module of an edited test file — whichever convention matches. Only returns
  a candidate when the derived path actually exists.
  """
  @spec test_file_candidates(String.t()) :: [map()]
  def test_file_candidates(edited_path) when is_binary(edited_path) do
    [to_test_path(edited_path), to_lib_path(edited_path), to_py_test_path(edited_path)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&file_read_candidate/1)
  end

  def test_file_candidates(_), do: []

  @doc """
  Classify what a just-completed, successful write-shaped tool call touched.

  Returns `{:paths, [String.t()]}` when the target path(s) could be pinned
  down, `:repo_wide` when the tool is known to write but its target could not
  be determined (or is inherently unscoped, like `git`), and `:none` when the
  call could not have changed anything on disk.
  """
  @spec classify_write(String.t(), map()) :: {:paths, [String.t()]} | :repo_wide | :none
  def classify_write("shell_execute", %{"command" => command}) when is_binary(command) do
    if ReadOnly.provably_read_only?(command), do: :none, else: :repo_wide
  end

  def classify_write("shell_execute", _args), do: :repo_wide

  def classify_write("multi_file_edit", %{"edits" => edits}) when is_list(edits) do
    case edits |> Enum.map(&target_of/1) |> Enum.reject(&is_nil/1) do
      [] -> :repo_wide
      paths -> {:paths, Enum.uniq(paths)}
    end
  end

  def classify_write(name, args) when name in ~w(
        file_write file_edit notebook_edit structural_edit
        file_delete file_move download file_create
      ) do
    case targets_of(args) do
      [] -> :repo_wide
      paths -> {:paths, paths}
    end
  end

  def classify_write(name, _args)
      when name in ~w(git task_write memory_write memory_save create_skill),
      do: :repo_wide

  def classify_write(_name, _args), do: :none

  # ── Private ────────────────────────────────────────────────────────────

  defp file_read_candidate(path),
    do: %{tool: "file_read", args: %{"path" => path}, watch: Cache.path_watch(path)}

  defp hidden?("." <> _), do: true
  defp hidden?(_), do: false

  defp target_of(entry) when is_map(entry), do: targets_of(entry) |> List.first()
  defp target_of(_), do: nil

  defp targets_of(args) when is_map(args) do
    ~w(path file_path target destination source from to new_path old_path)
    |> Enum.map(&Map.get(args, &1))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp targets_of(_), do: []

  # lib/foo/bar.ex -> test/foo/bar_test.exs (first "/lib/" occurrence only —
  # a path with a later, unrelated "lib" component must not also flip).
  defp to_test_path(path) do
    if String.ends_with?(path, ".ex") and String.contains?(path, "/lib/") do
      path
      |> String.replace("/lib/", "/test/", global: false)
      |> String.replace_suffix(".ex", "_test.exs")
    end
  end

  defp to_lib_path(path) do
    if String.ends_with?(path, "_test.exs") and String.contains?(path, "/test/") do
      path
      |> String.replace("/test/", "/lib/", global: false)
      |> String.replace_suffix("_test.exs", ".ex")
    end
  end

  # foo/bar.py <-> foo/test_bar.py (also checks a sibling tests/ dir), and the
  # reverse. Best-effort: Python's test layout is far less uniform than
  # Elixir's, so this only covers the single most common convention.
  defp to_py_test_path(path) do
    cond do
      String.ends_with?(path, ".py") and not test_py_name?(path) ->
        dir = Path.dirname(path)
        name = "test_" <> Path.basename(path)
        Path.join(dir, name)

      String.ends_with?(path, ".py") and test_py_name?(path) ->
        dir = Path.dirname(path)
        name = String.replace_prefix(Path.basename(path), "test_", "")
        Path.join(dir, name)

      true ->
        nil
    end
  end

  defp test_py_name?(path), do: String.starts_with?(Path.basename(path), "test_")
end
