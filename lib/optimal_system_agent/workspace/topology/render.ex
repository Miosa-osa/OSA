defmodule OptimalSystemAgent.Workspace.Topology.Render do
  @moduledoc """
  Operator-facing rendering of a `OptimalSystemAgent.Workspace.Topology` map.

  Two shapes, because they answer different questions:

    * `table/2` — "what are the pieces and what is each one?" A markdown table
      the TUI's table renderer sizes to content and word-wraps.
    * `tree/2` — "how are they nested?" An ASCII tree, which is the only view
      that shows a submodule living three levels down inside another component.

  ### Degrading at narrow widths

  Terminals get narrow and tables get ugly. `table/2` drops columns
  right-to-left by information value as the budget shrinks — `Stack` goes first,
  then `Type` — and below `@min_table_width` it abandons the table entirely for
  a two-line-per-component list, which never wraps into unreadable ribbons.
  The `Component` and `Role` columns are the last two standing because they are
  the two the operator's own hand-drawn map had.
  """

  alias OptimalSystemAgent.Workspace.Topology.Role

  @min_table_width 46
  @default_width 100

  @kind_label %{
    submodule: "submodule",
    nested_repo: "nested repo",
    workspace_member: "member",
    plain: "dir"
  }

  @doc """
  Full report: header line, workspace declarations, table, then tree.

  This is what the tool returns and what `/map` prints.
  """
  @spec report(map(), keyword()) :: String.t()
  def report(topo, opts \\ []) do
    width = opts[:width] || @default_width

    [
      header(topo),
      workspaces_section(topo),
      table(topo, opts) <> "\n",
      tree(topo, opts) |> maybe_section("Tree", width),
      footer(topo)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> String.trim()
  end

  # ── Header ─────────────────────────────────────────────────────────────

  defp header(topo) do
    git =
      cond do
        topo.root_is_git -> "git repo"
        true -> "not a git repo"
      end

    counts =
      topo.components
      |> Enum.frequencies_by(& &1.kind)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {kind, n} -> "#{n} #{plural(kind, n)}" end)

    detail = if counts == "", do: "no components detected", else: counts

    "## Workspace map — #{topo.name}\n\n`#{topo.root}` (#{git}) — #{detail}\n"
  end

  defp plural(:plain, 1), do: "plain directory"
  defp plural(:plain, _), do: "plain directories"
  defp plural(:nested_repo, 1), do: "nested repo"
  defp plural(:nested_repo, _), do: "nested repos"
  defp plural(:workspace_member, 1), do: "workspace member"
  defp plural(:workspace_member, _), do: "workspace members"
  defp plural(:submodule, 1), do: "submodule"
  defp plural(:submodule, _), do: "submodules"
  defp plural(kind, _), do: to_string(kind)

  defp workspaces_section(%{workspaces: []}), do: ""

  defp workspaces_section(%{workspaces: ws}) do
    lines =
      Enum.map_join(ws, "\n", fn w ->
        globs = w.globs |> Enum.take(4) |> Enum.join(", ")
        globs = if globs == "", do: "(no members declared)", else: globs
        "- **#{w.label}** (`#{w.manifest}`) → #{globs}"
      end)

    "**Workspaces declared**\n\n#{lines}\n"
  end

  defp footer(topo) do
    base =
      "_#{length(topo.components)} components, #{topo.scanned_dirs} dirs scanned in #{topo.elapsed_ms}ms._"

    if topo.truncated,
      do: base <> "\n\n> Walk hit its depth/component cap — some subtrees were not classified.",
      else: base
  end

  # ── Table ──────────────────────────────────────────────────────────────

  @doc """
  Markdown table of components. Degrades by dropping columns, then the table.
  """
  @spec table(map(), keyword()) :: String.t()
  def table(topo, opts \\ [])

  def table(%{components: []}, _opts), do: "_No components detected._"

  def table(topo, opts) do
    width = opts[:width] || @default_width

    if width < @min_table_width do
      compact_list(topo.components)
    else
      cols = columns_for(width)
      rows = Enum.map(topo.components, &row(&1, cols))
      markdown_table(Enum.map(cols, &header_for/1), rows)
    end
  end

  # Right-to-left column shedding. `Component` and `Role` are never dropped.
  defp columns_for(width) when width < 62, do: [:component, :role]
  defp columns_for(width) when width < 82, do: [:component, :type, :role]
  defp columns_for(_width), do: [:component, :type, :stack, :role]

  defp header_for(:component), do: "Component"
  defp header_for(:type), do: "Type"
  defp header_for(:stack), do: "Stack"
  defp header_for(:role), do: "Role"

  defp row(c, cols), do: Enum.map(cols, &cell(c, &1))

  defp cell(c, :component), do: c.path
  defp cell(c, :type), do: @kind_label[c.kind] || to_string(c.kind)
  defp cell(c, :stack), do: stack(c)
  defp cell(c, :role), do: role_cell(c)

  defp stack(%{language: nil, framework: nil}), do: "—"
  defp stack(%{language: lang, framework: nil}), do: lang
  defp stack(%{language: nil, framework: fw}), do: fw
  defp stack(%{language: lang, framework: fw}), do: "#{lang} / #{fw}"

  # The one honesty rule: an unknown role renders as a dash. We do not
  # substitute the directory name, the language, or a plausible-sounding word.
  defp role_cell(%{role: :unknown}), do: "—"
  defp role_cell(%{role: role}), do: Role.role_label(role)

  @doc "Render `rows` under `headers` as a GitHub-flavoured markdown table."
  @spec markdown_table([String.t()], [[String.t()]]) :: String.t()
  def markdown_table(headers, rows) do
    sep = Enum.map(headers, fn _ -> "---" end)

    [headers, sep | rows]
    |> Enum.map_join("\n", fn cells ->
      "| " <> Enum.map_join(cells, " | ", &escape/1) <> " |"
    end)
  end

  defp escape(nil), do: "—"

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end

  # Below the table floor: one component per two lines, no alignment at all.
  defp compact_list(components) do
    Enum.map_join(components, "\n", fn c ->
      meta =
        [@kind_label[c.kind], stack(c) != "—" && stack(c), role_cell(c) != "—" && role_cell(c)]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" · ")

      "#{c.path}\n  #{meta}"
    end)
  end

  # ── Tree ───────────────────────────────────────────────────────────────

  @doc """
  ASCII tree of the components, nested by path.

  Marks each node with its git classification, because that is precisely the
  information a flat listing (and `git ls-files`) throws away:

      ├── miosa-compute/            [nested repo]  Elixir / Phoenix — app
      └── vendor/subm/              [submodule]    — — unknown
  """
  @spec tree(map(), keyword()) :: String.t()
  def tree(topo, opts \\ [])

  def tree(%{components: []}, _opts), do: ""

  def tree(topo, opts) do
    width = opts[:width] || @default_width
    index = Map.new(topo.components, &{&1.path, &1})

    # Components live at arbitrary depths under directories that are NOT
    # themselves components (`apps/`, `sdks/`, `vendor/`). Rendering only
    # component paths would silently drop `vendor/subm` — the exact omission
    # this whole module exists to prevent — so every intermediate path segment
    # is synthesized as a plain group node.
    paths =
      topo.components
      |> Enum.flat_map(&prefixes(&1.path))
      |> Enum.uniq()
      |> Enum.sort()

    lines = render_level(children_of(paths, nil), paths, index, "", width)

    "#{topo.name}/\n" <> Enum.join(lines, "\n")
  end

  defp prefixes(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
  end

  defp children_of(paths, parent) do
    want = parent || "."
    Enum.filter(paths, &(Path.dirname(&1) == want))
  end

  defp render_level([], _paths, _index, _prefix, _width), do: []

  defp render_level(children, paths, index, prefix, width) do
    last = List.last(children)

    Enum.flat_map(children, fn path ->
      leaf? = path == last
      branch = if leaf?, do: "└── ", else: "├── "
      next_prefix = prefix <> if leaf?, do: "    ", else: "│   "

      label =
        case Map.fetch(index, path) do
          {:ok, c} -> node_label(c, width - String.length(prefix) - 4)
          :error -> Path.basename(path) <> "/"
        end

      sub =
        paths
        |> children_of(path)
        |> render_level(paths, index, next_prefix, width)

      [prefix <> branch <> label | sub]
    end)
  end

  defp node_label(c, avail) do
    base = Path.basename(c.path) <> "/"
    tag = "[#{@kind_label[c.kind] || c.kind}]"
    detail = Enum.join(Enum.reject([stack(c), role_cell(c)], &(&1 == "—")), " — ")

    full = Enum.join(Enum.reject([base, tag, detail], &(&1 == "")), "  ")

    cond do
      avail <= 0 -> base
      String.length(full) <= avail -> full
      String.length(base <> "  " <> tag) <= avail -> base <> "  " <> tag
      true -> base
    end
  end

  defp maybe_section("", _title, _width), do: ""
  defp maybe_section(body, title, _width), do: "**#{title}**\n\n```\n#{body}\n```\n"
end
