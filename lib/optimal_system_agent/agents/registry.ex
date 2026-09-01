defmodule OptimalSystemAgent.Agents.Registry do
  @moduledoc """
  Agent definition registry — loads AGENT.md files from built-in, project, and
  user agent directories.

  Agent definitions are markdown files with YAML frontmatter that describe
  specialized roles for subagent delegation. Later sources override earlier
  sources, so user agents can replace project or built-in agents with the same
  name.

  Stores definitions in :persistent_term for lock-free reads — same pattern
  as Tools.Registry for skills.
  """
  require Logger

  alias OptimalSystemAgent.Skills.Frontmatter

  @persistent_key {__MODULE__, :definitions}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Get an agent definition by name. Returns nil if not found."
  @spec get(String.t()) :: map() | nil
  def get(name) do
    definitions()
    |> Map.get(name)
  end

  @doc "List all available agent definitions."
  @spec list() :: [map()]
  def list do
    definitions()
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc "List available agent role names."
  @spec role_names() :: [String.t()]
  def role_names do
    definitions() |> Map.keys() |> Enum.sort()
  end

  @doc """
  Formatted context string for system prompt injection.

  Returns a markdown section listing available agent roles, their tiers,
  and descriptions. Returns nil when no agents are loaded.
  """
  @spec available_roles_context() :: String.t() | nil
  def available_roles_context do
    agents = list()

    if agents == [] do
      nil
    else
      rows =
        Enum.map_join(agents, "\n", fn a ->
          tier = a[:tier] || "specialist"
          summary = blank_to_nil(a[:description]) || ""
          hint = blank_to_nil(a[:when_to_use])
          base = "- **#{a.name}** (#{tier}): #{summary}"
          if hint, do: base <> " — Use when: #{hint}", else: base
        end)

      """
      ## Available Agent Roles

      When using the `delegate` tool, you can specify a `role` matching one of these:

      #{rows}

      You can also delegate without a role — the subagent gets a generic prompt with full tool access.

      ## When to Delegate
      - Task has 3+ independent parts that don't depend on each other
      - Task spans multiple domains (backend + frontend + tests)
      - A specialized role would handle part of the task better than doing it inline
      - Do NOT delegate simple single-file tasks
      """
    end
  end

  @doc """
  Load all agent definitions from built-in, project, and user directories.

  Called at application boot and can be called again to reload.
  """
  @spec load() :: :ok
  def load do
    dirs = discover_agent_dirs(OptimalSystemAgent.Workspace.Cwd.get())
    merged = load_from_paths(dirs)

    :persistent_term.put(@persistent_key, merged)

    counts =
      dirs
      |> Enum.map(fn {source, dir} -> {source, map_size(load_from_directory(dir, source))} end)
      |> Enum.map_join(", ", fn {source, count} -> "#{source}: #{count}" end)

    Logger.info("[AgentRegistry] Loaded #{map_size(merged)} agent definitions (#{counts})")

    :ok
  end

  @doc """
  Load agent definitions from explicit `{source, path}` entries.

  Later entries override earlier entries. This is primarily useful for tests
  and for callers that want deterministic discovery without relying on cwd.
  """
  @spec load_from_paths([{atom(), String.t()}]) :: map()
  def load_from_paths(paths) when is_list(paths) do
    Enum.reduce(paths, %{}, fn {source, dir}, acc ->
      Map.merge(acc, load_from_directory(dir, source))
    end)
  end

  @doc """
  Discover agent directories in load order.

  Precedence is built-in < project `.claude/agents` < project `.osa/agents` <
  user `~/.osa/agents`. Project directories are walked from repo root down to
  cwd so nearer files override broader files.

  ## Trust gate

  An agent definition's frontmatter declares `permission_tier` and
  `tools_allowed` — `permission_tier: bypassPermissions` resolves to `:full`,
  a subagent that prompts for nothing. That is a permission GRANT authored by
  whatever repository happens to be the cwd, so the project directories are
  withheld until the workspace is trusted, exactly as project settings, hooks
  and MCP servers are. Built-in and user (`~/.osa/agents`) directories are
  authored outside any workspace and always load.
  """
  @spec discover_agent_dirs(String.t()) :: [{atom(), String.t()}]
  def discover_agent_dirs(cwd \\ OptimalSystemAgent.Workspace.Cwd.get()) do
    [{:built_in, priv_agents_path()}] ++
      project_agent_dirs(cwd) ++ [{:user, user_agents_path()}]
  end

  defp project_agent_dirs(cwd) do
    dirs =
      cwd
      |> ancestor_dirs()
      |> Enum.flat_map(fn dir ->
        [
          {:project_claude, Path.join([dir, ".claude", "agents"])},
          {:project_osa, Path.join([dir, ".osa", "agents"])}
        ]
      end)
      |> Enum.filter(fn {_source, dir} -> File.dir?(dir) end)

    # One boundary, shared with settings / MCP / skills. This used to be a
    # private copy of the trust predicate plus its own warning; four such
    # copies existed and the fifth loader (skills) simply never grew one.
    OptimalSystemAgent.Workspace.ProjectResource.admit(dirs, :agents,
      cwd: cwd,
      why:
        "An agent definition can declare `permission_tier: bypassPermissions` and its own " <>
          "tool list, i.e. it is a permission grant authored by the repository."
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp definitions do
    :persistent_term.get(@persistent_key, %{})
  rescue
    ArgumentError -> %{}
  end

  defp priv_agents_path do
    case :code.priv_dir(:optimal_system_agent) do
      {:error, _} -> Path.join([File.cwd!(), "priv", "agents"])
      priv_dir -> Path.join(to_string(priv_dir), "agents")
    end
  rescue
    _ -> Path.join([File.cwd!(), "priv", "agents"])
  end

  defp user_agents_path do
    Path.expand("~/.osa/agents")
  end

  defp load_from_directory(dir, source) do
    if File.dir?(dir) do
      # Support both flat files (priv/agents/architect.md) and
      # subdirectories (~/. osa/agents/my-agent/AGENT.md)
      md_files = Path.wildcard(Path.join(dir, "*.md"))

      agent_dirs =
        dir
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.map(fn d -> Path.join([dir, d, "AGENT.md"]) end)
        |> Enum.filter(&File.exists?/1)

      (md_files ++ agent_dirs)
      |> Enum.reject(&disabled?/1)
      |> Enum.reduce(%{}, fn path, acc ->
        case parse_agent_file(path, source) do
          {:ok, agent} -> Map.put(acc, agent.name, agent)
          :error -> acc
        end
      end)
    else
      %{}
    end
  rescue
    e ->
      Logger.warning("[AgentRegistry] Failed to load from #{dir}: #{inspect(e)}")
      %{}
  end

  # An agent definition is disabled by a `.disabled` marker BESIDE it: the
  # directory marker for `<agent>/AGENT.md`, and a `<name>.md.disabled` sibling
  # for a flat `<name>.md` (which previously had no way to be disabled at all).
  defp disabled?(path) do
    File.exists?(Path.join(Path.dirname(path), ".disabled")) or
      File.exists?(path <> ".disabled")
  rescue
    _ -> false
  end

  defp parse_agent_file(path, source) do
    content = File.read!(path)

    case Frontmatter.parse(content) do
      {:ok, meta, body} when is_map(meta) ->
        {:ok, build_agent(path, source, meta, String.trim(body))}

      # The file has NO frontmatter block at all: a plain markdown system
      # prompt. Nothing was declared, so nothing is being discarded.
      {:error, :missing} ->
        {:ok,
         %{
           name: Path.basename(path, ".md"),
           description: "",
           when_to_use: "",
           tier: :specialist,
           triggers: [],
           tools_allowed: nil,
           tools_blocked: [],
           max_iterations: nil,
           force_background: false,
           permission_tier: :subagent,
           system_prompt: OptimalSystemAgent.Utils.Bom.strip(content),
           source_path: path,
           source: source
         }}

      # The file DECLARES frontmatter that will not parse. It may well declare
      # `tools_allowed`/`tools_blocked`/`permission_tier`. Loading it anyway
      # used to hand the model an UNRESTRICTED subagent whose whole file —
      # frontmatter included — became the system prompt: a security control
      # silently discarded. Refuse to load instead, and say why.
      {:error, reason} ->
        Logger.error(
          "[AgentRegistry] REFUSING to load subagent #{path}: " <>
            "#{Frontmatter.explain(reason)}. Any tools_allowed/tools_blocked it declares " <>
            "cannot be read, and loading it without them would grant the subagent more " <>
            "access than its author wrote. Fix the frontmatter to load this agent."
        )

        :error
    end
  rescue
    e ->
      Logger.warning("[AgentRegistry] Failed to parse #{path}: #{inspect(e)}")
      :error
  end

  defp parse_tier("elite"), do: :elite
  defp parse_tier("specialist"), do: :specialist
  defp parse_tier("utility"), do: :utility
  defp parse_tier(tier) when is_atom(tier), do: parse_tier(Atom.to_string(tier))
  defp parse_tier(_), do: :specialist

  defp build_agent(path, source, meta, body) do
    name =
      meta["name"] ||
        Path.basename(path, ".md")
        |> then(fn n ->
          if n == "AGENT", do: Path.basename(Path.dirname(path)), else: n
        end)

    %{
      name: to_string(name),
      description: to_string(meta["description"] || ""),
      when_to_use: to_string(first_present(meta, ["when_to_use", "whenToUse"]) || ""),
      tier: parse_tier(meta["tier"]),
      triggers: List.wrap(meta["triggers"] || []) |> Enum.map(&to_string/1),
      tools_allowed: parse_tool_list(first_present(meta, ["tools_allowed", "tools"])),
      tools_blocked:
        parse_tool_list(
          first_present(meta, ["tools_blocked", "disallowedTools", "disallowed_tools"])
        ) ||
          [],
      max_iterations: first_present(meta, ["max_iterations", "maxTurns", "max_turns"]),
      permission_tier:
        parse_permission_tier(
          first_present(meta, ["permission_tier", "permissionMode", "permission_mode"])
        ),
      model: nullable_string(meta["model"]),
      provider: nullable_string(meta["provider"]),
      effort: nullable_string(meta["effort"]),
      background: parse_bool(meta["background"]),
      # Force background even when the caller foregrounds (research fan-outs that
      # must never lock the parent's turn). See delegate `background?/2`.
      force_background: parse_bool(meta["force_background"]) == true,
      isolation: parse_isolation(meta["isolation"]),
      skills: List.wrap(first_present(meta, ["skills"]) || []) |> Enum.map(&to_string/1),
      mcp_servers: first_present(meta, ["mcp_servers", "mcpServers"]),
      hooks: meta["hooks"],
      initial_prompt: first_present(meta, ["initial_prompt", "initialPrompt"]),
      memory: meta["memory"],
      system_prompt: body,
      source_path: path,
      source: source
    }
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp first_present(meta, keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(meta, key), do: Map.get(meta, key), else: nil
    end)
  end

  defp parse_tool_list(nil), do: nil
  defp parse_tool_list("~"), do: nil
  defp parse_tool_list("*"), do: nil
  defp parse_tool_list(""), do: []

  defp parse_tool_list(list) when is_binary(list) do
    list
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      ["*"] -> nil
      tools -> tools
    end
  end

  defp parse_tool_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_tool_list(_), do: nil

  defp parse_permission_tier(nil), do: :subagent
  defp parse_permission_tier("default"), do: :subagent
  defp parse_permission_tier("acceptEdits"), do: :workspace
  defp parse_permission_tier("bypassPermissions"), do: :full
  defp parse_permission_tier("plan"), do: :read_only
  defp parse_permission_tier("read_only"), do: :read_only
  defp parse_permission_tier("read-only"), do: :read_only
  defp parse_permission_tier("readonly"), do: :read_only
  defp parse_permission_tier("workspace"), do: :workspace
  defp parse_permission_tier("subagent"), do: :subagent
  defp parse_permission_tier("full"), do: :full

  defp parse_permission_tier(value) when is_atom(value),
    do: parse_permission_tier(Atom.to_string(value))

  defp parse_permission_tier(_), do: :subagent

  defp parse_isolation("worktree"), do: :worktree
  defp parse_isolation(:worktree), do: :worktree
  defp parse_isolation(_), do: nil

  defp parse_bool(true), do: true
  defp parse_bool("true"), do: true
  defp parse_bool(_), do: false

  defp nullable_string(nil), do: nil
  defp nullable_string(value), do: to_string(value)

  defp ancestor_dirs(cwd) do
    cwd
    |> Path.expand()
    |> do_ancestor_dirs([])
  end

  defp do_ancestor_dirs(dir, acc) do
    acc = [dir | acc]

    cond do
      File.exists?(Path.join(dir, ".git")) ->
        acc

      Path.dirname(dir) == dir ->
        acc

      true ->
        do_ancestor_dirs(Path.dirname(dir), acc)
    end
  end
end
