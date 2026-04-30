defmodule OptimalSystemAgent.Tools.Builtins.CreateAgent.Handler do
  @moduledoc """
  Validation and execution logic for `create_agent`.

  Stages:
    * `validate/2`           — verify required fields are present and non-empty
    * `check_permissions/2`  — always allow (write to user-owned ~/.osa/agents/)
    * `execute/2`             — build AGENT.md, write it, reload `AgentRegistry`
  """

  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  alias OptimalSystemAgent.Tools.Builtins.CreateAgent.Constants
  alias OptimalSystemAgent.Tools.UseContext
  require Logger

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"name" => name, "instructions" => instructions} = input, _ctx)
      when is_binary(name) and is_binary(instructions) do
    cond do
      String.trim(name) == "" ->
        {:error, "name must not be blank", -32_602}

      String.trim(instructions) == "" ->
        {:error, "instructions must not be blank", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(%{"name" => _}, _ctx),
    do: {:error, "Missing required parameter: instructions", -32_602}

  def validate(%{"instructions" => _}, _ctx),
    do: {:error, "Missing required parameter: name", -32_602}

  def validate(_input, _ctx),
    do: {:error, "Missing required parameters: name, instructions", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(args, _ctx) do
    name =
      args
      |> Map.get("name", "")
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")

    description = Map.get(args, "description", "")
    tier = Map.get(args, "tier", "specialist")
    instructions = Map.get(args, "instructions", "")
    tools_blocked_raw = Map.get(args, "tools_blocked", "")

    blocked_list =
      if tools_blocked_raw == "" do
        "[]"
      else
        items =
          tools_blocked_raw
          |> String.split(",")
          |> Enum.map(&"\"#{String.trim(&1)}\"")
          |> Enum.join(", ")

        "[#{items}]"
      end

    content =
      """
      ---
      name: #{name}
      description: #{description}
      tier: #{tier}
      tools_blocked: #{blocked_list}
      ---

      #{instructions}
      """
      |> String.trim()

    agents_dir = Path.expand("#{Constants.agents_base_dir()}/#{name}")
    agent_file = Path.join(agents_dir, "AGENT.md")

    try do
      File.mkdir_p!(agents_dir)
      File.write!(agent_file, content)
      AgentRegistry.load()
      Logger.info("[CreateAgent] Created agent '#{name}' at #{agent_file}")

      {:ok,
       "Created agent '#{name}' (#{tier}). " <>
         "It's now available for delegation with `delegate(role: \"#{name}\", ...)`."}
    rescue
      e -> {:error, "Failed to create agent: #{Exception.message(e)}"}
    end
  end
end
