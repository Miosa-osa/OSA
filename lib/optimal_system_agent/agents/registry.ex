defmodule OptimalSystemAgent.Agents.Registry do
  @moduledoc """
  Agent definition registry — loads AGENT.md files from priv/agents/ and ~/.osa/agents/.

  Agent definitions are markdown files with YAML frontmatter that describe
  specialized roles for subagent delegation. User agents (~/.osa/agents/)
  override built-in agents (priv/agents/) with the same name.

  Stores definitions in :persistent_term for lock-free reads — same pattern
  as Tools.Registry for skills.
  """
  require Logger

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
          "- **#{a.name}** (#{tier}): #{a[:description] || ""}"
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
  Load all agent definitions from priv/agents/ and ~/.osa/agents/.

  Called at application boot and can be called again to reload.
  User agents override built-in agents with the same name.
  """
  @spec load() :: :ok
  def load do
    priv_agents = load_from_directory(priv_agents_path())
    user_agents = load_from_directory(user_agents_path())

    # User overrides built-in
    merged = Map.merge(priv_agents, user_agents)

    :persistent_term.put(@persistent_key, merged)

    Logger.info(
      "[AgentRegistry] Loaded #{map_size(merged)} agent definitions " <>
        "(#{map_size(priv_agents)} built-in, #{map_size(user_agents)} user)"
    )

    :ok
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

  defp load_from_directory(dir) do
    if File.dir?(dir) do
      # Support both flat files (priv/agents/architect.md) and
      # subdirectories (~/. osa/agents/my-agent/AGENT.md)
      md_files = Path.wildcard(Path.join(dir, "*.md"))

      agent_dirs =
        dir
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.reject(fn d -> File.exists?(Path.join([dir, d, ".disabled"])) end)
        |> Enum.map(fn d -> Path.join([dir, d, "AGENT.md"]) end)
        |> Enum.filter(&File.exists?/1)

      (md_files ++ agent_dirs)
      |> Enum.reduce(%{}, fn path, acc ->
        case parse_agent_file(path) do
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

  defp parse_agent_file(path) do
    content = File.read!(path)

    case String.split(content, "---", parts: 3) do
      ["", frontmatter, body] ->
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, meta} ->
            name =
              meta["name"] ||
                Path.basename(path, ".md")
                |> then(fn n ->
                  if n == "AGENT", do: Path.basename(Path.dirname(path)), else: n
                end)

            {:ok,
             %{
               name: to_string(name),
               description: to_string(meta["description"] || ""),
               tier: parse_tier(meta["tier"]),
               triggers: List.wrap(meta["triggers"] || []) |> Enum.map(&to_string/1),
               tools_allowed: parse_tool_list(meta["tools_allowed"]),
               tools_blocked: parse_tool_list(meta["tools_blocked"]) || [],
               max_iterations: meta["max_iterations"],
               system_prompt: String.trim(body),
               source_path: path
             }}

          _ ->
            :error
        end

      _ ->
        # No frontmatter — treat entire content as system prompt
        name = Path.basename(path, ".md")

        {:ok,
         %{
           name: name,
           description: "",
           tier: :specialist,
           triggers: [],
           tools_allowed: nil,
           tools_blocked: [],
           max_iterations: nil,
           system_prompt: content,
           source_path: path
         }}
    end
  rescue
    e ->
      Logger.warning("[AgentRegistry] Failed to parse #{path}: #{inspect(e)}")
      :error
  end

  defp parse_tier("elite"), do: :elite
  defp parse_tier("specialist"), do: :specialist
  defp parse_tier("utility"), do: :utility
  defp parse_tier(_), do: :specialist

  defp parse_tool_list(nil), do: nil
  defp parse_tool_list("~"), do: nil
  defp parse_tool_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_tool_list(_), do: nil
end
