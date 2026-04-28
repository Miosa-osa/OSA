defmodule OptimalSystemAgent.Tools.Builtins.ListAgents do
  @moduledoc """
  List available agent definitions and their capabilities.

  Allows the parent agent to introspect its roster before delegating —
  check what specialized roles are available, what tier they run at,
  what tools they have access to, and what skills they carry.
  """
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry

  @impl true
  def name, do: "list_agents"

  @impl true
  def description do
    "List all available agent roles and their capabilities. " <>
      "Use this to check what specialized agents are loaded before " <>
      "deciding how to delegate a complex task. Returns each agent's " <>
      "name, tier, description, and tool restrictions."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "role" => %{
          "type" => "string",
          "description" => "Optional: get details for a specific role. Omit to list all."
        }
      }
    }
  end

  @impl true
  def execute(args) do
    role = Map.get(args, "role")

    if role && role != "" do
      case AgentRegistry.get(role) do
        nil ->
          {:ok,
           "No agent definition found for '#{role}'. You can still delegate to this role — the subagent will run with generic instructions and full tool access."}

        agent ->
          detail = format_agent_detail(agent)
          {:ok, detail}
      end
    else
      agents = AgentRegistry.list()
      skills = list_skills()

      if agents == [] do
        {:ok,
         "No agent definitions loaded. You can still delegate tasks — subagents will run with generic instructions.\n\nAvailable skills: #{skills}"}
      else
        lines =
          Enum.map_join(agents, "\n", fn a ->
            blocked =
              if a[:tools_blocked] != [],
                do: " | blocked: #{Enum.join(a.tools_blocked, ", ")}",
                else: ""

            "- **#{a.name}** (#{a[:tier] || :specialist}): #{a[:description]}#{blocked}"
          end)

        {:ok,
         "## Loaded Agent Roles (#{length(agents)})\n\n#{lines}\n\n## Available Skills\n#{skills}\n\nYou can also delegate to roles not in this list — they run as generic subagents with full tool access."}
      end
    end
  end

  defp format_agent_detail(agent) do
    blocked =
      if agent[:tools_blocked] != [],
        do: "\nBlocked tools: #{Enum.join(agent.tools_blocked, ", ")}",
        else: "\nBlocked tools: none (full access)"

    prompt_preview =
      if agent[:system_prompt],
        do: "\nPrompt preview: #{String.slice(agent.system_prompt, 0, 200)}...",
        else: ""

    triggers =
      if agent[:triggers] != [], do: "\nTriggers: #{Enum.join(agent.triggers, ", ")}", else: ""

    """
    ## #{agent.name} (#{agent[:tier] || :specialist})
    #{agent[:description]}#{blocked}#{triggers}#{prompt_preview}
    """
    |> String.trim()
  end

  defp list_skills do
    try do
      skills = OptimalSystemAgent.Tools.Registry.list_skills()

      if skills == [] do
        "none loaded"
      else
        Enum.map_join(skills, ", ", fn s -> s.name end)
      end
    rescue
      _ -> "unavailable"
    end
  end
end
