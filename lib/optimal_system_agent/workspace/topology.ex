defmodule OptimalSystemAgent.Workspace.Topology do
  @moduledoc """
  Structural map of a "constellation" workspace — a tree whose components are a
  mix of plain directories, **git submodules**, and **nested independent git
  repositories**, plus whatever ecosystem workspaces (Elixir umbrella, Cargo,
  pnpm/npm/yarn, Go modules, Terraform/Helm) actually define its shape.

  ## Why this exists — the git blind spot

  Git makes two of those three component kinds invisible to the parent repo:

      $ git ls-files            # at a constellation root
      .gitmodules
      README.md
      nested-repo               # ← ONE entry. Its 4,000 files: not listed.
      vendor/subm               # ← ONE entry (a gitlink). Same.
      plaindir/p.txt

  A nested repo is stored as a bare gitlink; a submodule likewise. Any code that
  enumerates a workspace via `git ls-files` therefore sees a directory *name*
  where a whole subtree should be, and silently loses every file inside it.
  `git status` is worse: a dirty nested repo reports **clean** at the parent.

  `rev-parse --show-toplevel` has the mirror-image problem: run it inside a
  nested repo and it answers with the *nested* repo, not the constellation. Any
  root-anchored discovery (project instruction files, "am I in a monorepo")
  anchored on that answer stops at the inner boundary and never sees the
  workspace the operator is actually working in.

  This module refuses to ask git for the shape of the tree. It walks the
  filesystem, then uses git only to *classify* what it already found.

  ## Cost model — this is NEVER per-turn work

  The walk stats a bounded number of directories and shells out to
  `git check-ignore` once per directory listing. That is far too expensive to
  run while assembling context. So:

    * nothing in the per-turn path calls `detect/2`;
    * `get/2` serves from an ETS cache keyed by workspace root;
    * the cache is validated by a **fingerprint** — `{size, mtime}` of the small
      set of signal files the walk actually depended on (`.gitmodules`, every
      component manifest, workspace declarations). Revalidation is O(components)
      `File.stat` calls with no directory walking, so a hit is cheap and a stale
      entry is impossible to serve after a `.gitmodules`/manifest edit;
    * `workspace_root/1` — the one function context discovery calls — only walks
      *upward* from a directory and never triggers `detect/2`.

  See `OptimalSystemAgent.Workspace.Topology.Render` for the operator-facing
  table/tree, and `OptimalSystemAgent.Tools.Builtins.WorkspaceMap` for the tool.
  """

  require Logger

  alias OptimalSystemAgent.Workspace.Topology.Role

  @cache_table :osa_workspace_topology_cache

  # Depth is measured in directory levels below the root. 3 covers
  # `sdks/typescript/packages/core` — the deepest shape real constellations use
  # — without turning the walk into a full-tree crawl.
  @default_max_depth 3
  @max_components 250
  @max_dirs_scanned 4_000

  # Never descended into. These are build/vendor output: enormous, and never a
  # component the operator thinks of as part of the map.
  # NOTE: `vendor` is deliberately absent. It is the single most common home for
  # git submodules (`vendor/<name>`), and blanket-skipping it was exactly the
  # class of blind spot this module exists to remove. Genuine vendor *dumps* are
  # excluded by `vendor_dump?/1` on evidence instead of on the name.
  @skip_dirs MapSet.new(~w(
    .git .hg .svn .jj
    node_modules bower_components .bundle
    _build deps .elixir_ls .lexical
    target dist build out .next .nuxt .svelte-kit .turbo .parcel-cache
    .venv venv env __pycache__ .mypy_cache .pytest_cache .ruff_cache
    .terraform .terragrunt-cache
    .gradle .m2 .cargo .stack-work
    coverage .nyc_output .cache .idea .vscode .DS_Store
    tmp temp .tmp log logs
  ))

  @type kind :: :submodule | :nested_repo | :workspace_member | :plain

  @type component :: %{
          path: String.t(),
          abs_path: String.t(),
          kind: kind(),
          name: String.t(),
          language: String.t() | nil,
          framework: String.t() | nil,
          role: Role.role(),
          evidence: [String.t()],
          depth: pos_integer(),
          workspace_type: atom() | nil
        }

  @type t :: %{
          root: String.t(),
          name: String.t(),
          root_is_git: boolean(),
          workspaces: [map()],
          components: [component()],
          truncated: boolean(),
          scanned_dirs: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          fingerprint: [{String.t(), integer(), integer()}]
        }

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Cached topology for `root`.

  Returns the cached value when the fingerprint still matches, otherwise
  recomputes. Safe to call from a tool or a slash command; **not** safe to call
  per turn — see the cost model in the moduledoc.

  Options are forwarded to `detect/2`. Pass `refresh: true` to force a rewalk.
  """
  @spec get(String.t(), keyword()) :: t()
  def get(root, opts \\ []) do
    root = Path.expand(root)
    ensure_table()

    cond do
      opts[:refresh] ->
        recompute(root, opts)

      true ->
        case :ets.lookup(@cache_table, root) do
          [{^root, %{fingerprint: fp} = topo}] ->
            if fingerprint_valid?(fp), do: topo, else: recompute(root, opts)

          _ ->
            recompute(root, opts)
        end
    end
  rescue
    e ->
      Logger.debug("[Topology] get failed for #{root}: #{Exception.message(e)}")
      empty(root)
  end

  @doc "Drop the cached topology for `root` (or all roots when `:all`)."
  @spec invalidate(String.t() | :all) :: :ok
  def invalidate(:all) do
    ensure_table()
    :ets.delete_all_objects(@cache_table)
    :ok
  rescue
    _ -> :ok
  end

  def invalidate(root) when is_binary(root) do
    ensure_table()
    :ets.delete(@cache_table, Path.expand(root))
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  The outermost workspace root enclosing `dir` — the fix for the
  `rev-parse --show-toplevel` blind spot.

  Walks *upward* only (cheap, no directory listing beyond a handful of
  `File.exists?` probes) and returns the highest ancestor that still looks like
  a workspace root: a git repo, an Elixir umbrella, a Cargo/pnpm/npm workspace,
  or a `go.work`. Crucially, it does **not** stop at the first `.git` it finds —
  that is exactly the behavior that makes a nested independent repo hide the
  constellation above it.

  Stops at `$HOME` and at the filesystem root, neither of which is ever a
  workspace. Returns `nil` when nothing above `dir` qualifies.
  """
  @spec workspace_root(String.t() | nil) :: String.t() | nil
  def workspace_root(nil), do: nil

  def workspace_root(dir) do
    start = Path.expand(dir)
    boundary = stop_boundaries()

    start
    |> ancestors()
    |> Enum.reject(&MapSet.member?(boundary, &1))
    |> Enum.filter(&workspace_root?/1)
    |> List.last()
  rescue
    _ -> nil
  end

  @doc """
  Every workspace root enclosing `dir`, innermost first.

  Context discovery uses this to search the inner repo *and* the constellation
  above it, instead of only whichever one git names.
  """
  @spec enclosing_roots(String.t() | nil) :: [String.t()]
  def enclosing_roots(nil), do: []

  def enclosing_roots(dir) do
    boundary = stop_boundaries()

    dir
    |> Path.expand()
    |> ancestors()
    |> Enum.reject(&MapSet.member?(boundary, &1))
    |> Enum.filter(&workspace_root?/1)
  rescue
    _ -> []
  end

  @doc "True when `dir` is a submodule of the repo it sits in."
  @spec submodule?(String.t()) :: boolean()
  def submodule?(dir) do
    abs = Path.expand(dir)
    parent_repo = enclosing_repo(Path.dirname(abs))

    parent_repo != nil and
      MapSet.member?(submodule_paths(parent_repo), Path.relative_to(abs, parent_repo))
  rescue
    _ -> false
  end

  # ── Detection (uncached) ───────────────────────────────────────────────

  @doc """
  Walk `root` and classify every significant subtree. Uncached — prefer `get/2`.

  Options:

    * `:max_depth` — directory levels below root (default #{@default_max_depth})
    * `:max_components` — hard cap (default #{@max_components})
    * `:respect_gitignore` — default `true`
  """
  @spec detect(String.t(), keyword()) :: t()
  def detect(root, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    root = Path.expand(root)
    max_depth = opts[:max_depth] || @default_max_depth
    max_components = opts[:max_components] || @max_components
    gitignore? = Keyword.get(opts, :respect_gitignore, true)

    submodules = submodule_paths(root)
    workspaces = detect_workspaces(root)
    member_index = workspace_member_index(root, workspaces)

    state = %{
      root: root,
      submodules: submodules,
      members: member_index,
      gitignore?: gitignore?,
      max_depth: max_depth,
      max_components: max_components,
      components: [],
      scanned: 0,
      truncated: false
    }

    state = walk(root, 0, state)
    components = Enum.sort_by(state.components, & &1.path)

    fingerprint =
      [Path.join(root, ".gitmodules") | workspace_manifests(root, workspaces)]
      |> Enum.concat(Enum.map(components, &manifest_path/1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&stat_entry/1)

    %{
      root: root,
      name: Path.basename(root),
      root_is_git: File.exists?(Path.join(root, ".git")),
      workspaces: workspaces,
      components: components,
      truncated: state.truncated,
      scanned_dirs: state.scanned,
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      fingerprint: fingerprint
    }
  rescue
    e ->
      Logger.debug("[Topology] detect failed for #{root}: #{Exception.message(e)}")
      empty(Path.expand(root))
  end

  # ── Walk ───────────────────────────────────────────────────────────────

  defp walk(_dir, _depth, %{truncated: true} = state), do: state

  defp walk(dir, depth, state) do
    cond do
      # Children of `dir` land at `depth + 1`, so stopping at `>=` is what makes
      # `max_depth: 1` mean "top-level components only".
      depth >= state.max_depth ->
        state

      state.scanned >= @max_dirs_scanned or length(state.components) >= state.max_components ->
        %{state | truncated: true}

      true ->
        state = %{state | scanned: state.scanned + 1}
        children = child_dirs(dir, state)

        Enum.reduce(children, state, fn child, acc ->
          visit(child, depth + 1, acc)
        end)
    end
  end

  defp visit(dir, depth, state) do
    rel = Path.relative_to(dir, state.root)
    kind = classify(dir, rel, state)
    info = if kind == :plain and not significant?(dir), do: nil, else: Role.infer(dir, hint(rel))

    state =
      if info do
        component = %{
          path: rel,
          abs_path: dir,
          kind: kind,
          name: info.name,
          language: info.language,
          framework: info.framework,
          role: info.role,
          evidence: info.evidence,
          depth: depth,
          workspace_type: Map.get(state.members, rel)
        }

        %{state | components: [component | state.components]}
      else
        state
      end

    # Descend past a classified component only when it is itself a container of
    # further components (an umbrella's `apps/`, a `sdks/` tree, a submodule
    # holding its own workspace). Leaf components are terminal: recursing into a
    # Rust crate to find its `src/` adds noise, not shape.
    if info == nil or container?(dir, kind) do
      walk(dir, depth, state)
    else
      state
    end
  end

  # A directory earns a row when there is *evidence* it is a component, not
  # because it exists. Bare organizational folders are traversed, not listed.
  defp significant?(dir) do
    Role.primary_manifest(dir) != nil or
      File.exists?(Path.join(dir, ".git")) or
      File.regular?(Path.join(dir, "Chart.yaml")) or
      File.regular?(Path.join(dir, "main.tf")) or
      Path.wildcard(Path.join(dir, "*.tf")) != [] or
      # Documentation trees carry no manifest, so naming is the only evidence
      # there is. It is weak evidence, but it is evidence — and `Role.infer/2`
      # still refuses to call it `docs` unless the contents agree.
      Path.basename(dir) in ["docs", "documentation", "website"]
  end

  defp classify(dir, rel, state) do
    cond do
      MapSet.member?(state.submodules, rel) -> :submodule
      File.exists?(Path.join(dir, ".git")) -> :nested_repo
      Map.has_key?(state.members, rel) -> :workspace_member
      true -> :plain
    end
  end

  # `apps/`-style containers and any dir whose own children are workspace
  # members still need descending into.
  defp container?(dir, kind) do
    kind in [:submodule, :nested_repo] or File.dir?(Path.join(dir, "apps")) or
      File.regular?(Path.join(dir, "pnpm-workspace.yaml")) or
      File.regular?(Path.join(dir, "go.work"))
  end

  defp hint(rel) do
    case rel |> Path.split() |> List.first() do
      seg when seg in ["sdks", "sdk", "clients"] -> :sdk
      seg when seg in ["infra", "infrastructure", "deploy", "deployment", "terraform", "helm", "charts"] -> :infra
      seg when seg in ["docs", "documentation", "website"] -> :docs
      _ -> nil
    end
  end

  defp child_dirs(dir, state) do
    entries =
      case File.ls(dir) do
        {:ok, entries} -> Enum.sort(entries)
        _ -> []
      end

    dirs =
      entries
      |> Enum.reject(&MapSet.member?(@skip_dirs, &1))
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.filter(fn e ->
        path = Path.join(dir, e)
        File.dir?(path) and not symlink?(path) and not vendor_dump?(e, path)
      end)

    kept = if state.gitignore? and dirs != [], do: reject_ignored(dir, dirs), else: dirs

    Enum.map(kept, &Path.join(dir, &1))
  end

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  # A `vendor/` directory is skipped only with proof that it is a dependency
  # dump — `modules.txt` (Go) or `bundle/` (Ruby). A `vendor/` holding
  # submodules has neither and is walked normally.
  defp vendor_dump?("vendor", path) do
    File.regular?(Path.join(path, "modules.txt")) or File.dir?(Path.join(path, "bundle"))
  end

  defp vendor_dump?(_name, _path), do: false

  # One `git check-ignore` per directory listing, batched over all children via
  # argv. `System.cmd/3` cannot write to a child's stdin, so `--stdin` (and with
  # it `-z`, which git rejects without `--stdin`) is unavailable; newline
  # parsing is safe here because every argument is a single directory *name*.
  # Exit 0 = at least one path ignored, 1 = none ignored, 128 = not a repo.
  defp reject_ignored(dir, names) do
    # stderr is folded into the capture purely to keep git's "not a git
    # repository" chatter off the operator's terminal; it is never parsed,
    # because only exit 0 (= something matched) reads the output at all.
    case System.cmd("git", ["check-ignore", "--"] ++ names, cd: dir, stderr_to_stdout: true) do
      {out, 0} ->
        ignored = out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
        Enum.reject(names, &MapSet.member?(ignored, &1))

      _ ->
        names
    end
  rescue
    _ -> names
  catch
    _, _ -> names
  end

  # ── Git facts ──────────────────────────────────────────────────────────

  @doc "Submodule paths declared in `root/.gitmodules`, relative to `root`."
  @spec submodule_paths(String.t()) :: MapSet.t()
  def submodule_paths(root) do
    path = Path.join(root, ".gitmodules")

    case File.read(path) do
      {:ok, body} ->
        ~r/^\s*path\s*=\s*(.+?)\s*$/m
        |> Regex.scan(body)
        |> Enum.map(fn [_, p] -> String.trim(p) end)
        |> Enum.reject(&(&1 == ""))
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  # Nearest ancestor (inclusive) holding a `.git`. Pure filesystem — no shelling
  # out, so it works for both gitdir-file submodules and real repos.
  defp enclosing_repo(dir) do
    dir
    |> Path.expand()
    |> ancestors()
    |> Enum.find(&File.exists?(Path.join(&1, ".git")))
  end

  # ── Ecosystem workspaces ───────────────────────────────────────────────

  @doc "Ecosystem workspace declarations at `root` (umbrella, cargo, pnpm, …)."
  @spec detect_workspaces(String.t()) :: [map()]
  def detect_workspaces(root) do
    [
      elixir_umbrella(root),
      cargo_workspace(root),
      pnpm_workspace(root),
      node_workspace(root),
      go_workspace(root)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp elixir_umbrella(root) do
    mix = Path.join(root, "mix.exs")

    with true <- File.regular?(mix),
         {:ok, body} <- File.read(mix),
         [_, apps] <- Regex.run(~r/apps_path:\s*"([^"]+)"/, body) do
      %{type: :elixir_umbrella, manifest: "mix.exs", globs: [Path.join(apps, "*")], label: "Elixir umbrella"}
    else
      _ -> nil
    end
  end

  defp cargo_workspace(root) do
    cargo = Path.join(root, "Cargo.toml")

    with true <- File.regular?(cargo),
         {:ok, body} <- File.read(cargo),
         true <- String.contains?(body, "[workspace]") do
      globs =
        case Regex.run(~r/\[workspace\][^\[]*?members\s*=\s*\[(.*?)\]/s, body) do
          [_, list] -> Regex.scan(~r/"([^"]+)"/, list) |> Enum.map(fn [_, m] -> m end)
          _ -> []
        end

      %{type: :cargo_workspace, manifest: "Cargo.toml", globs: globs, label: "Cargo workspace"}
    else
      _ -> nil
    end
  end

  defp pnpm_workspace(root) do
    file = Path.join(root, "pnpm-workspace.yaml")

    with true <- File.regular?(file),
         {:ok, body} <- File.read(file) do
      globs =
        ~r/^\s*-\s*['"]?([^'"\n]+?)['"]?\s*$/m
        |> Regex.scan(body)
        |> Enum.map(fn [_, g] -> String.trim(g) end)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "!")))

      %{type: :pnpm_workspace, manifest: "pnpm-workspace.yaml", globs: globs, label: "pnpm workspace"}
    else
      _ -> nil
    end
  end

  defp node_workspace(root) do
    file = Path.join(root, "package.json")

    with true <- File.regular?(file),
         {:ok, body} <- File.read(file),
         [_, list] <- Regex.run(~r/"workspaces"\s*:\s*(?:\{[^}]*"packages"\s*:\s*)?\[(.*?)\]/s, body) do
      globs = Regex.scan(~r/"([^"]+)"/, list) |> Enum.map(fn [_, g] -> g end)
      label = if File.regular?(Path.join(root, "yarn.lock")), do: "yarn workspaces", else: "npm workspaces"
      %{type: :node_workspace, manifest: "package.json", globs: globs, label: label}
    else
      _ -> nil
    end
  end

  defp go_workspace(root) do
    file = Path.join(root, "go.work")

    with true <- File.regular?(file),
         {:ok, body} <- File.read(file) do
      globs =
        ~r/^\s*(?:use\s+)?\.?\/?([\w.\-\/]+)\s*$/m
        |> Regex.scan(body)
        |> Enum.map(fn [_, g] -> g end)
        |> Enum.reject(&(&1 in ["", "use", "go", "(", ")"]))

      %{type: :go_workspace, manifest: "go.work", globs: globs, label: "Go workspace"}
    else
      _ -> nil
    end
  end

  # rel_path -> workspace type, for every member a declaration expands to.
  defp workspace_member_index(root, workspaces) do
    Enum.reduce(workspaces, %{}, fn ws, acc ->
      Enum.reduce(ws.globs, acc, fn glob, acc2 ->
        Path.join(root, glob)
        |> Path.wildcard()
        |> Enum.filter(&File.dir?/1)
        |> Enum.reduce(acc2, fn dir, acc3 ->
          Map.put_new(acc3, Path.relative_to(dir, root), ws.type)
        end)
      end)
    end)
  rescue
    _ -> %{}
  end

  defp workspace_manifests(root, workspaces),
    do: Enum.map(workspaces, &Path.join(root, &1.manifest))

  # ── Workspace-root probes ──────────────────────────────────────────────

  defp workspace_root?(dir) do
    File.exists?(Path.join(dir, ".git")) or
      File.regular?(Path.join(dir, "go.work")) or
      File.regular?(Path.join(dir, "pnpm-workspace.yaml")) or
      umbrella_mix?(dir) or
      cargo_workspace_toml?(dir) or
      node_workspaces_json?(dir)
  end

  defp umbrella_mix?(dir) do
    case File.read(Path.join(dir, "mix.exs")) do
      {:ok, body} -> Regex.match?(~r/apps_path:/, body)
      _ -> false
    end
  end

  defp cargo_workspace_toml?(dir) do
    case File.read(Path.join(dir, "Cargo.toml")) do
      {:ok, body} -> String.contains?(body, "[workspace]")
      _ -> false
    end
  end

  defp node_workspaces_json?(dir) do
    case File.read(Path.join(dir, "package.json")) do
      {:ok, body} -> Regex.match?(~r/"workspaces"\s*:/, body)
      _ -> false
    end
  end

  # Innermost-first list of `dir` and every ancestor above it.
  defp ancestors(dir) do
    Stream.unfold(dir, fn
      nil ->
        nil

      current ->
        parent = Path.dirname(current)
        {current, if(parent == current, do: nil, else: parent)}
    end)
    |> Enum.to_list()
  end

  defp stop_boundaries do
    home = System.user_home() || System.get_env("HOME")
    MapSet.new(Enum.reject([home && Path.expand(home), "/", "."], &is_nil/1))
  end

  # ── Cache ──────────────────────────────────────────────────────────────

  defp recompute(root, opts) do
    topo = detect(root, opts)
    ensure_table()
    :ets.insert(@cache_table, {root, topo})
    topo
  end

  defp fingerprint_valid?(fp) when is_list(fp) do
    Enum.all?(fp, fn {path, size, mtime} -> stat_entry(path) == {path, size, mtime} end)
  end

  defp fingerprint_valid?(_), do: false

  # Missing files fingerprint as {-1, -1}, so creating a `.gitmodules` that did
  # not exist at walk time invalidates the entry just like editing one.
  defp stat_entry(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} -> {path, size, mtime}
      _ -> {path, -1, -1}
    end
  end

  defp manifest_path(%{abs_path: abs}) do
    case Role.primary_manifest(abs) do
      {file, _lang} -> Path.join(abs, file)
      nil -> nil
    end
  end

  defp ensure_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp empty(root) do
    %{
      root: root,
      name: Path.basename(root),
      root_is_git: false,
      workspaces: [],
      components: [],
      truncated: false,
      scanned_dirs: 0,
      elapsed_ms: 0,
      fingerprint: []
    }
  end
end
