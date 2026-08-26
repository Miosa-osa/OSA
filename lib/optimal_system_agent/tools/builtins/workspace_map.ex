defmodule OptimalSystemAgent.Tools.Builtins.WorkspaceMap do
  @moduledoc """
  `workspace_map` — structural map of a multi-component ("constellation")
  workspace.

  Answers the question no other tool can: *what are the pieces of this tree, and
  which of them is git hiding?* `file_glob` and `file_grep` see files;
  `git ls-files` sees one bare entry where a nested repo or submodule should be.
  This tool walks the filesystem and classifies each subtree as a plain
  directory, a git submodule, a nested independent repository, or a member of a
  declared ecosystem workspace — then infers each one's language, framework and
  role from its manifest.

  Cached per workspace root and invalidated on `.gitmodules`/manifest change, so
  repeated calls in one session are effectively free. See
  `OptimalSystemAgent.Workspace.Topology`.
  """

  @behaviour MiosaTools.Behaviour

  alias OptimalSystemAgent.Workspace.Cwd
  alias OptimalSystemAgent.Workspace.Topology
  alias OptimalSystemAgent.Workspace.Topology.Render

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  @impl true
  # Deferred: discoverable mid-turn via `tool_search`, absent from the default
  # toolbox. Every schema in the default set is re-sent on EVERY request, so a
  # tool most turns never touch is paid for by all of them.
  @impl true
  def should_defer?, do: true

  def name, do: "workspace_map"

  # Description convention (matching the tool-prompt style used across builtins):
  # lead with what it produces, then the ONE situation it is uniquely for, then
  # the explicit "don't reach for this when…" so the model does not call it as a
  # generic directory lister.
  @impl true
  def description do
    """
    Produce a structural map of the current workspace: every significant component, \
    how git treats it (plain directory, submodule, or nested independent repository), \
    which ecosystem workspace it belongs to (Elixir umbrella, Cargo, pnpm/npm/yarn, Go), \
    and its inferred language, framework and role.

    Use this ONCE at the start of work in an unfamiliar multi-component repo — a monorepo, \
    an umbrella, or a tree with submodules — to learn the component boundaries before \
    searching or editing. It is the only way to see subtrees that `git ls-files` and \
    `git status` hide: a nested repo or submodule appears to the parent repo as a single \
    entry, so its files are invisible to git-based enumeration.

    Do NOT use it to list a directory's contents (use `dir_list`), to find files by name \
    (use `file_glob`), or to search file contents (use `file_grep`). Roles it cannot \
    establish from evidence are reported as unknown rather than guessed.
    """
    |> String.trim()
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "Workspace root to map. Defaults to the outermost workspace enclosing the current directory, which is what you want in a nested repo."
        },
        "format" => %{
          "type" => "string",
          "enum" => ["report", "table", "tree"],
          "description" =>
            "\"report\" (default) = header + table + tree; \"table\" = markdown table only; \"tree\" = nesting only."
        },
        "max_depth" => %{
          "type" => "integer",
          "description" => "Directory levels below the root to classify. Default 3, max 6."
        },
        "refresh" => %{
          "type" => "boolean",
          "description" =>
            "Force a rewalk instead of serving the cached map. Only needed after creating or moving components in this session."
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(args) when is_map(args) do
    root = resolve_root(Map.get(args, "path"))

    cond do
      root == nil ->
        {:error, "Could not resolve a workspace root to map."}

      not File.dir?(root) ->
        {:error, "#{root} is not a directory."}

      true ->
        opts = [
          max_depth: clamp_depth(Map.get(args, "max_depth")),
          refresh: Map.get(args, "refresh") == true
        ]

        topo = Topology.get(root, opts)

        output =
          case Map.get(args, "format", "report") do
            "table" -> Render.table(topo, width: 100)
            "tree" -> Render.tree(topo, width: 100)
            _ -> Render.report(topo, width: 100)
          end

        {:ok, output,
         %{
           root: topo.root,
           component_count: length(topo.components),
           workspaces: Enum.map(topo.workspaces, & &1.type),
           truncated: topo.truncated
         }}
    end
  rescue
    e -> {:error, "workspace_map failed: #{Exception.message(e)}"}
  end

  def execute(_), do: execute(%{})

  # ── Helpers ────────────────────────────────────────────────────────────

  # Default to the OUTERMOST enclosing workspace, not `Cwd.get/0`. Inside a
  # nested repo those differ, and the outer one is the map the operator means.
  defp resolve_root(path) when is_binary(path) and path != "" do
    Path.expand(path, Cwd.get())
  end

  defp resolve_root(_) do
    cwd = Cwd.get()
    Topology.workspace_root(cwd) || cwd
  end

  defp clamp_depth(n) when is_integer(n) and n > 0, do: min(n, 6)

  defp clamp_depth(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> clamp_depth(i)
      _ -> 3
    end
  end

  defp clamp_depth(_), do: 3
end
