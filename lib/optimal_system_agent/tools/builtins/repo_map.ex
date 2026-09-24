defmodule OptimalSystemAgent.Tools.Builtins.RepoMap do
  @moduledoc """
  `repo_map` — the cheap way to consult the live repo model
  (`OptimalSystemAgent.RepoMap`) instead of re-grepping the tree or
  re-running `git status` to rediscover structure that is already known.

  Five actions, one tool:

    * `"summary"` (default) — one line: file count, checkout identity
      (branch/sha/dirty), last test status.
    * `"tree"` — the tracked file tree.
    * `"symbols"` — cached symbols for one file (`file` param required);
      computed and cached on first ask if not already known.
    * `"git_state"` — the verifiable "which checkout is this" answer: branch,
      HEAD sha, dirty files, ahead/behind upstream.
    * `"test_status"` — the last observed test run's outcome.

  Cached per workspace root and kept current incrementally (tool-result
  observation + a background watcher) — see the `RepoMap` moduledoc. This
  tool only ever reads that cache; pass `refresh: true` to force a full
  rebuild (a `git ls-files` + a handful of `git` calls — cheap, but still not
  something to do every turn).
  """

  @behaviour MiosaTools.Behaviour

  alias OptimalSystemAgent.RepoMap
  alias OptimalSystemAgent.Workspace.Cwd
  alias OptimalSystemAgent.Workspace.Topology

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  # Discoverable via `tool_search`; most turns never need it, so it does not
  # belong in the default toolbox schema sent on every request.
  def should_defer?, do: true

  @impl true
  def name, do: "repo_map"

  @impl true
  def description do
    """
    Consult the live repo model instead of re-grepping the tree or re-running `git status` \
    to rediscover structure OSA already knows: file tree, cached per-file symbols, the last \
    test run's outcome, and a verifiable "which checkout is this" (branch, HEAD sha, dirty \
    files, ahead/behind upstream) — the guard against silently working in a stale clone.

    Actions: "summary" (default, one line), "tree", "symbols" (needs `file`), "git_state", \
    "test_status".
    """
    |> String.trim()
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["summary", "tree", "symbols", "git_state", "test_status"],
          "description" => "What to return. Defaults to \"summary\"."
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Workspace root. Defaults to the outermost workspace enclosing the current directory."
        },
        "file" => %{
          "type" => "string",
          "description" =>
            "Path (relative to the root) to get symbols for. Required for \"symbols\"."
        },
        "refresh" => %{
          "type" => "boolean",
          "description" => "Force a full rebuild instead of serving the cached map."
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(args) when is_map(args) do
    root = resolve_root(Map.get(args, "path"))
    opts = [refresh: Map.get(args, "refresh") == true]

    cond do
      root == nil ->
        {:error, "Could not resolve a workspace root to map."}

      not File.dir?(root) ->
        {:error, "#{root} is not a directory."}

      true ->
        dispatch(Map.get(args, "action", "summary"), root, opts, args)
    end
  rescue
    e -> {:error, "repo_map failed: #{Exception.message(e)}"}
  end

  def execute(_), do: execute(%{})

  # ── Dispatch ─────────────────────────────────────────────────────────

  defp dispatch("summary", root, opts, _args), do: {:ok, RepoMap.summary(root, opts)}

  defp dispatch("git_state", root, opts, _args),
    do: {:ok, format_git_state(RepoMap.git_state(root, opts))}

  defp dispatch("test_status", root, opts, _args),
    do: {:ok, format_test_status(RepoMap.test_status(root, opts))}

  defp dispatch("tree", root, opts, _args), do: {:ok, format_tree(RepoMap.get(root, opts))}

  defp dispatch("symbols", root, opts, args) do
    case Map.get(args, "file") do
      file when is_binary(file) and file != "" ->
        case RepoMap.symbols_for_file(root, file, opts) do
          {:ok, symbols} -> {:ok, format_symbols(file, symbols)}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, "action \"symbols\" requires a \"file\" parameter."}
    end
  end

  defp dispatch(other, _root, _opts, _args),
    do:
      {:error,
       "Unknown action #{inspect(other)}. Use summary, tree, symbols, git_state, or test_status."}

  # ── Rendering ────────────────────────────────────────────────────────

  @max_tree_display 1_000

  defp format_tree(model) do
    all_paths = model.files |> Map.keys() |> Enum.sort()
    shown = Enum.take(all_paths, @max_tree_display)

    note =
      if length(all_paths) > @max_tree_display do
        " (showing first #{@max_tree_display} of #{length(all_paths)})"
      else
        ""
      end

    truncated_note = if model.truncated, do: " — walk truncated at the file cap", else: ""

    header =
      "#{model.file_count} file(s) tracked under #{model.root}#{truncated_note}#{note}:\n"

    header <> render_tree(shown)
  end

  defp render_tree(paths) do
    paths
    |> Enum.reduce(%{}, fn path, acc -> put_in_tree(acc, Path.split(path)) end)
    |> render_node(0)
  end

  defp put_in_tree(acc, [last]), do: Map.put_new(acc, last, :leaf)

  defp put_in_tree(acc, [dir | rest]) do
    child =
      case Map.get(acc, dir, %{}) do
        :leaf -> %{}
        map -> map
      end

    Map.put(acc, dir, put_in_tree(child, rest))
  end

  defp render_node(tree, depth) do
    tree
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n", fn {name, sub} ->
      indent = String.duplicate("  ", depth)

      case sub do
        :leaf -> "#{indent}#{name}"
        map -> "#{indent}#{name}/\n#{render_node(map, depth + 1)}"
      end
    end)
  end

  defp format_symbols(file, []) do
    "No symbols cached for #{file} (the file may genuinely have none, or has an " <>
      "unsupported extension)."
  end

  defp format_symbols(file, symbols) do
    lines =
      Enum.map_join(symbols, "\n", fn {line_num, type, name} ->
        padded = line_num |> Integer.to_string() |> String.pad_leading(4)
        "  L#{padded}  [#{type}] #{name}"
      end)

    "Symbols in #{file} (from the repo map):\n#{lines}"
  end

  defp format_git_state(nil) do
    "Not a git repository (or git state could not be read) at this root."
  end

  defp format_git_state(git) do
    dirty_note =
      if git.dirty_count > 0 do
        preview = Enum.map_join(Enum.take(git.dirty_files, 20), "\n", &("    " <> &1))
        "#{git.dirty_count} dirty file(s):\n#{preview}"
      else
        "clean"
      end

    upstream_note =
      case {git.ahead, git.behind, git.upstream} do
        {nil, nil, nil} -> "no upstream tracked"
        {a, b, up} -> "+#{a}/-#{b} vs #{up}"
      end

    """
    Branch: #{git.branch}
    HEAD: #{git.head_sha || "unknown"} (#{git.head_sha_short || "?"})
    Last commit: #{git.last_commit_at || "unknown"}
    Working tree: #{dirty_note}
    Upstream: #{upstream_note}
    """
    |> String.trim_trailing()
  end

  defp format_test_status(nil) do
    "No test run has been observed yet in this session."
  end

  defp format_test_status(%{status: status, tool: tool, summary: summary}) do
    "Last test run (#{tool}): #{status |> to_string() |> String.upcase()} — #{summary}"
  end

  # ── Root resolution (mirrors `WorkspaceMap`) ──────────────────────────

  defp resolve_root(path) when is_binary(path) and path != "", do: Path.expand(path, Cwd.get())

  defp resolve_root(_) do
    cwd = Cwd.get()
    Topology.workspace_root(cwd) || cwd
  end
end
