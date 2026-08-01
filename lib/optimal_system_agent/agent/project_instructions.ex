defmodule OptimalSystemAgent.Agent.ProjectInstructions do
  @moduledoc """
  Directory-scoped, lazy instruction injection (port of opencode's
  `session/instruction.ts` `resolve/3`).

  Instead of front-loading every `AGENTS.md`/`CLAUDE.md` in a repo, we inject the
  **nearest ancestor** instruction file *only when the agent actually reads or
  edits a file in that subtree* — attached once, deduplicated so the same
  guidance is never injected twice.

  ## How it works

  `Context` scans the conversation for the file paths the agent has touched
  (`file_read`/`file_edit`/`file_write`/`notebook_edit` tool calls). For each
  touched file we walk upward from its directory toward the worktree root and
  find the closest instruction file (`AGENTS.md`, `CLAUDE.md`, `GROK.md`, …).
  That file's guidance is injected as a `<system-reminder>`, subject to four
  dedup rules that mirror opencode:

    1. **Root already front-loaded** — the top-level project instruction file is
       injected up front by `ContextDiscovery`; we skip it here (`system_paths`).
    2. **Directly read** — if the agent already read the instruction file itself
       as a tool result, its content is in context; don't re-inject.
    3. **Same subtree** — two files under one `AGENTS.md` inject it once (the
       shared `seen` set within a single `resolve/2` call).
    4. **Already claimed** — once injected for a session it stays claimed, so
       later turns don't re-inject it (the `claimed` set threaded by `Context`).

  The core `resolve/2` is a **pure function**: pass `:root`, `:system_paths`,
  `:already_read`, and `:claimed` explicitly and it returns
  `{results, updated_claimed}` with no filesystem-boundary surprises. `Context`
  supplies real filesystem/session state; tests drive it with fixtures.
  """

  require Logger

  alias OptimalSystemAgent.Agent.ContextDiscovery

  # Candidate instruction filenames, in priority order. First existing file in a
  # directory wins (so a directory with both AGENTS.md and CLAUDE.md uses
  # AGENTS.md — matching opencode's precedence).
  @instruction_files [
    "AGENTS.md",
    "agents.md",
    "CLAUDE.md",
    "claude.md",
    "GROK.md",
    ".grok/GROK.md"
  ]

  # Per-file char cap so a single nested instruction file cannot dominate the
  # dynamic tier. ~2k tokens.
  @per_file_char_cap 8_000

  @type result :: %{path: String.t(), content: String.t()}

  @doc "The instruction filenames considered, in precedence order."
  @spec instruction_files() :: [String.t()]
  def instruction_files, do: @instruction_files

  @doc """
  Resolve directory-scoped instruction files for a set of touched paths.

  `read_paths` — file paths the agent read/edited this session (absolute or
  relative to `:working_dir`).

  Options:

    * `:root` — worktree boundary. The upward walk stops **below** this dir
      (exclusive), so the root's own instruction file is never lazily injected
      (it is front-loaded). Defaults to the git root of `:working_dir`, else
      `:working_dir` itself.
    * `:working_dir` — base for expanding relative `read_paths` and computing
      defaults for `:root`/`:system_paths`.
    * `:system_paths` — `MapSet`/list of absolute instruction paths already
      front-loaded (skip). Defaults to the nearest instruction file walking
      `working_dir → root`, matching what `ContextDiscovery` injects.
    * `:already_read` — `MapSet`/list of absolute paths the agent read directly
      (skip if the nearest instruction file is one of them). Defaults to the
      expanded `read_paths`.
    * `:claimed` — `MapSet` of instruction paths already injected earlier this
      session (skip). Defaults to empty.
    * `:instruction_files` — override candidate filenames (tests).

  Returns `{results, updated_claimed}` where `results` is a list of
  `%{path, content}` (nearest-first per touched file, deduped) and
  `updated_claimed` folds the newly injected paths into `:claimed`.
  """
  @spec resolve([String.t()], keyword()) :: {[result()], MapSet.t()}
  def resolve(read_paths, opts \\ []) when is_list(read_paths) do
    working_dir = opts[:working_dir]

    root =
      (opts[:root] || (working_dir && outermost_root(working_dir)) || working_dir)
      |> normalize_dir()

    candidates = opts[:instruction_files] || @instruction_files

    expanded_reads =
      read_paths
      |> Enum.map(&expand_path(&1, working_dir))
      |> Enum.reject(&is_nil/1)

    system =
      case opts[:system_paths] do
        nil -> default_system_paths(working_dir, root, candidates)
        sp -> to_set(sp)
      end

    already = to_set(opts[:already_read] || expanded_reads)
    claimed0 = to_set(opts[:claimed])

    # Fold over the touched files. `seen` (this call) + `claimed` (this session)
    # together guarantee each instruction file is injected at most once.
    {results, claimed, _seen} =
      Enum.reduce(expanded_reads, {[], claimed0, MapSet.new()}, fn target, {acc, claimed, seen} ->
        case nearest_for(target, root, candidates, system, already, claimed, seen) do
          nil ->
            {acc, claimed, seen}

          found ->
            case read_and_render(found) do
              nil ->
                # Unreadable/blocked: still claim so we don't retry every turn.
                {acc, MapSet.put(claimed, found), MapSet.put(seen, found)}

              content ->
                {acc ++ [%{path: found, content: content}], MapSet.put(claimed, found),
                 MapSet.put(seen, found)}
            end
        end
      end)

    {results, claimed}
  end

  @doc """
  Render resolved instruction results into a `<system-reminder>` block, or `nil`
  when there is nothing to inject.
  """
  @spec render([result()]) :: String.t() | nil
  def render([]), do: nil
  def render(nil), do: nil

  def render(results) when is_list(results) do
    body =
      Enum.map_join(results, "\n\n---\n\n", fn %{path: path, content: content} ->
        "Instructions from: #{path}\n#{content}"
      end)

    """
    ## Directory-Scoped Instructions

    <system-reminder>
    The following instructions were loaded because you accessed files in these
    subdirectories. They apply to work in those subtrees and take precedence over
    more general guidance for files under them.
    </system-reminder>

    #{body}
    """
    |> String.trim()
  end

  @doc """
  Find the nearest instruction file at or above `dir` up to `root` inclusive.
  Returns an absolute path or `nil`. Used to compute the front-loaded
  `system_paths` (the file `ContextDiscovery` already injects).
  """
  @spec system_paths(String.t() | nil, String.t() | nil) :: MapSet.t()
  def system_paths(working_dir, root),
    do: default_system_paths(working_dir, normalize_dir(root), @instruction_files)

  @doc "First existing instruction file directly inside `dir`, or `nil`."
  @spec find_in(String.t(), [String.t()]) :: String.t() | nil
  def find_in(dir, candidates \\ @instruction_files) do
    Enum.find_value(candidates, fn name ->
      path = Path.expand(Path.join(dir, name))
      if File.regular?(path), do: path
    end)
  end

  # ── walk ───────────────────────────────────────────────────────────────

  # Walk upward from the directory containing `target`, up to (but not
  # including) `root`, returning the first eligible instruction file.
  defp nearest_for(target, root, candidates, system, already, claimed, seen) do
    do_walk(parent_dir(target), root, target, candidates, system, already, claimed, seen)
  end

  defp do_walk(nil, _root, _target, _candidates, _system, _already, _claimed, _seen), do: nil

  defp do_walk(current, root, target, candidates, system, already, claimed, seen) do
    cond do
      # Left the worktree, or reached the root itself (root's file is
      # front-loaded, so the walk is exclusive of root — like opencode's
      # `current !== root`).
      root != nil and (current == root or not under_or_equal?(current, root)) ->
        nil

      true ->
        case find_in(current, candidates) do
          found
          when is_binary(found) and found != target ->
            if MapSet.member?(system, found) or MapSet.member?(already, found) or
                 MapSet.member?(claimed, found) or MapSet.member?(seen, found) do
              # Skip this one but keep walking up — an ancestor may still have a
              # not-yet-injected file (mirrors opencode's `continue`).
              ascend(current, root, target, candidates, system, already, claimed, seen)
            else
              found
            end

          _ ->
            ascend(current, root, target, candidates, system, already, claimed, seen)
        end
    end
  end

  defp ascend(current, root, target, candidates, system, already, claimed, seen) do
    parent = parent_dir(current)
    if parent == current, do: nil, else: do_walk(parent, root, target, candidates, system, already, claimed, seen)
  end

  # ── system paths (front-loaded file) ────────────────────────────────────

  # Compute the nearest instruction file walking working_dir → root INCLUSIVE.
  # This is the file ContextDiscovery front-loads, which we must not lazily
  # re-inject.
  defp default_system_paths(working_dir, root, candidates) do
    case nearest_inclusive(normalize_dir(working_dir), root, candidates) do
      nil -> MapSet.new()
      path -> MapSet.new([path])
    end
  end

  defp nearest_inclusive(nil, _root, _candidates), do: nil

  defp nearest_inclusive(dir, root, candidates) do
    case find_in(dir, candidates) do
      found when is_binary(found) ->
        found

      _ ->
        cond do
          root != nil and dir == root -> nil
          root != nil and not under_or_equal?(dir, root) -> nil
          true ->
            parent = parent_dir(dir)
            if parent == dir, do: nil, else: nearest_inclusive(parent, root, candidates)
        end
    end
  end

  # ── io ──────────────────────────────────────────────────────────────────

  defp read_and_render(path) do
    case File.read(path) do
      {:ok, content} when byte_size(content) > 0 ->
        case ContextDiscovery.scan_for_injection(content) do
          :clean ->
            content
            |> String.trim()
            |> truncate(@per_file_char_cap)

          {:blocked, reason} ->
            Logger.warning(
              "[ProjectInstructions] BLOCKED #{path} — prompt injection detected: #{reason}"
            )

            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp truncate(content, cap) when byte_size(content) <= cap, do: content

  defp truncate(content, cap) do
    String.slice(content, 0, cap) <> "\n\n[... truncated ...]"
  end

  # ── path helpers ─────────────────────────────────────────────────────────

  # The upward walk's boundary. `git rev-parse --show-toplevel` is the wrong
  # boundary in a constellation: inside a **nested independent repo** (or a
  # submodule) git answers with the inner repo, so every instruction file
  # between the inner repo and the real monorepo root is silently skipped.
  # `Topology.workspace_root/1` keeps climbing past inner `.git` boundaries to
  # the outermost enclosing workspace, and falls back to the git root when there
  # is nothing above it.
  defp outermost_root(dir) do
    OptimalSystemAgent.Workspace.Topology.workspace_root(dir) || git_root(dir)
  rescue
    _ -> git_root(dir)
  end

  defp git_root(nil), do: nil

  defp git_root(dir) do
    case OptimalSystemAgent.Git.cmd(["rev-parse", "--show-toplevel"], cd: dir, stderr_to_stdout: true) do
      {root, 0} -> String.trim(root)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize_dir(nil), do: nil
  defp normalize_dir(dir), do: Path.expand(dir)

  defp expand_path(nil, _base), do: nil
  defp expand_path("", _base), do: nil

  defp expand_path(path, base) when is_binary(path) do
    if base, do: Path.expand(path, base), else: Path.expand(path)
  end

  defp expand_path(_path, _base), do: nil

  defp parent_dir(path) do
    parent = Path.dirname(path)
    if parent == path, do: nil, else: parent
  end

  # True when `dir` is `root` or nested below it.
  defp under_or_equal?(dir, root) do
    dir == root or String.starts_with?(dir, root <> "/")
  end

  defp to_set(nil), do: MapSet.new()
  defp to_set(%MapSet{} = set), do: set
  defp to_set(list) when is_list(list), do: MapSet.new(list)
end
