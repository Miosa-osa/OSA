defmodule OptimalSystemAgent.Channels.CLI.AgentTree do
  @moduledoc """
  ASCII tree renderer for agent hierarchies.

  Renders a visual tree showing agent status, role, and per-agent stats
  with box-drawing connectors (├──, └──, │).

  Display example:

      Agent Hierarchy:
      └── ◉ coordinator
          ├── ✓ researcher (4 tools · 8.2k)
          ├── ◉ implementer (2 tools · 3.1k)
          │   ├── ✓ test-writer (1 tool · 1.2k)
          │   └── ◉ code-reviewer
          └── ○ validator (waiting)
  """

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()

  @status_icons %{
    running: "#{IO.ANSI.yellow()}◉#{IO.ANSI.reset()}",
    completed: "#{IO.ANSI.green()}✓#{IO.ANSI.reset()}",
    failed: "#{IO.ANSI.red()}✗#{IO.ANSI.reset()}",
    idle: "#{IO.ANSI.faint()}○#{IO.ANSI.reset()}"
  }

  @type agent_node :: %{
          id: String.t(),
          role: String.t(),
          status: :running | :completed | :failed | :idle,
          children: [agent_node()],
          stats: %{tools: non_neg_integer(), tokens: non_neg_integer()} | nil
        }

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Render an agent tree to the terminal.

  Accepts a list of root `agent_node` maps, a single map, or an empty list.
  Each node may contain a `:children` key with nested nodes.
  """
  @spec render([agent_node()] | agent_node()) :: :ok
  def render([]) do
    IO.puts("#{@dim}  No active agents#{@reset}")
  end

  def render(agents) when is_list(agents) do
    IO.puts("")
    IO.puts("#{@bold}  Agent Hierarchy:#{@reset}")

    agents
    |> Enum.with_index()
    |> Enum.each(fn {agent, idx} ->
      render_node(agent, "  ", idx == length(agents) - 1)
    end)

    IO.puts("")
  end

  def render(%{} = agent) do
    render([agent])
  end

  @doc """
  Build a nested agent tree from a flat list of agent maps.

  Agents are grouped by `:parent_id`. Agents with no `:parent_id` (or a nil
  value) become roots. The original map is preserved on each node, with a
  `:children` key added.
  """
  @spec build_tree([map()]) :: [agent_node()]
  def build_tree(agents) when is_list(agents) do
    by_parent = Enum.group_by(agents, & &1[:parent_id])
    roots = Map.get(by_parent, nil, [])

    Enum.map(roots, fn root ->
      build_subtree(root, by_parent)
    end)
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp render_node(agent, prefix, is_last) do
    connector = if is_last, do: "└── ", else: "├── "
    icon = status_icon(agent[:status])
    role = agent[:role] || agent[:id] || "unknown"
    stats = format_stats(agent[:stats])

    IO.puts("#{prefix}#{connector}#{icon} #{role}#{stats}")

    children = agent[:children] || []
    child_prefix = prefix <> if(is_last, do: "    ", else: "│   ")

    children
    |> Enum.with_index()
    |> Enum.each(fn {child, idx} ->
      render_node(child, child_prefix, idx == length(children) - 1)
    end)
  end

  defp status_icon(status) do
    Map.get(@status_icons, status, @status_icons[:idle])
  end

  defp format_stats(nil), do: ""

  defp format_stats(%{tools: tools, tokens: tokens}) do
    parts =
      []
      |> maybe_add_tools(tools)
      |> maybe_add_tokens(tokens)

    if parts == [] do
      ""
    else
      " #{@dim}(#{Enum.join(parts, " · ")})#{@reset}"
    end
  end

  defp format_stats(_), do: ""

  defp maybe_add_tools(parts, n) when is_integer(n) and n > 0 do
    label = if n == 1, do: "1 tool", else: "#{n} tools"
    parts ++ [label]
  end

  defp maybe_add_tools(parts, _), do: parts

  defp maybe_add_tokens(parts, n) when is_integer(n) and n > 0 do
    parts ++ [format_tokens(n)]
  end

  defp maybe_add_tokens(parts, _), do: parts

  defp format_tokens(n) when n < 1_000, do: "#{n}"
  defp format_tokens(n), do: "#{Float.round(n / 1_000, 1)}k"

  defp build_subtree(agent, by_parent) do
    children =
      by_parent
      |> Map.get(agent[:id], [])
      |> Enum.map(fn child -> build_subtree(child, by_parent) end)

    Map.put(agent, :children, children)
  end
end
