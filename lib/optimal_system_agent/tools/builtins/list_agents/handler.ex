defmodule OptimalSystemAgent.Tools.Builtins.ListAgents.Handler do
  @moduledoc """
  Validation and execution logic for `list_agents`.

  Stages:
    * `validate/2`           — confirm input is a map (always passes for this tool)
    * `check_permissions/2`  — read-only; always allow
    * `execute/2`             — delegate to `AgentRegistry` and `Tools.Registry`
  """

  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(input, _ctx) when is_map(input), do: {:ok, input}

  def validate(_input, _ctx),
    do: {:error, "Input must be a map", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()}
  def execute(args, _ctx) do
    role = Map.get(args, "role")

    if role && role != "" do
      case AgentRegistry.get(role) do
        nil ->
          {:ok,
           "No agent definition found for '#{role}'. You can still delegate to this role — " <>
             "the subagent will run with generic instructions and full tool access."}

        agent ->
          {:ok, format_agent_detail(agent)}
      end
    else
      agents = AgentRegistry.list()
      skills = list_skills()

      if agents == [] do
        {:ok,
         "No agent definitions loaded. You can still delegate tasks — subagents will run " <>
           "with generic instructions.\n\nAvailable skills: #{skills}"}
      else
        lines =
          Enum.map_join(agents, "\n", fn a ->
            allowed =
              case a[:tools_allowed] do
                nil -> "all tools"
                [] -> "no tools"
                tools -> "tools: #{Enum.join(tools, ", ")}"
              end

            blocked =
              if a[:tools_blocked] != [],
                do: " | blocked: #{Enum.join(a.tools_blocked, ", ")}",
                else: ""

            permission = a[:permission_tier] || :subagent
            source = a[:source] || :unknown

            "- **#{a.name}** (#{a[:tier] || :specialist}, #{permission}, #{source}): " <>
              "#{a[:description]} | #{allowed}#{blocked}"
          end)

        {:ok,
         "## Loaded Agent Roles (#{length(agents)})\n\n#{lines}\n\n" <>
           "## Available Skills\n#{skills}\n\n" <>
           "You can also delegate to roles not in this list — they run as generic subagents with full tool access."}
      end
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp format_agent_detail(agent) do
    blocked =
      if agent[:tools_blocked] != [],
        do: "\nBlocked tools: #{Enum.join(agent.tools_blocked, ", ")}",
        else: "\nBlocked tools: none (full access)"

    allowed =
      case agent[:tools_allowed] do
        nil -> "\nAllowed tools: all"
        [] -> "\nAllowed tools: none"
        tools -> "\nAllowed tools: #{Enum.join(tools, ", ")}"
      end

    source =
      "\nSource: #{agent[:source] || :unknown}" <>
        if(agent[:source_path], do: " (#{agent.source_path})", else: "")

    permission = "\nPermission tier: #{agent[:permission_tier] || :subagent}"

    prompt_preview =
      if agent[:system_prompt],
        do: "\nPrompt preview: #{String.slice(agent.system_prompt, 0, 200)}...",
        else: ""

    triggers =
      if agent[:triggers] != [],
        do: "\nTriggers: #{Enum.join(agent.triggers, ", ")}",
        else: ""

    """
    ## #{agent.name} (#{agent[:tier] || :specialist})
    #{agent[:description]}#{permission}#{allowed}#{blocked}#{source}#{triggers}#{prompt_preview}
    """
    |> String.trim()
  end

  defp list_skills do
    try do
      skills = OptimalSystemAgent.Tools.Registry.list_skills()

      if skills == [],
        do: "none loaded",
        else: Enum.map_join(skills, ", ", fn s -> s.name end)
    rescue
      _ -> "unavailable"
    end
  end
end
