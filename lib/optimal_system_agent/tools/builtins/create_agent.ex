defmodule OptimalSystemAgent.Tools.Builtins.CreateAgent do
  @moduledoc """
  Create a new agent definition on the fly.

  Writes an AGENT.md file to ~/.osa/agents/ and reloads the AgentRegistry
  so the new role is immediately available for delegation.
  """
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  require Logger

  @impl true
  def deferred?, do: true

  @impl true
  def name, do: "create_agent"

  @impl true
  def description do
    "Create a new specialized agent role that can be used with the delegate tool. " <>
      "The agent definition is saved to ~/.osa/agents/ and immediately available. " <>
      "Use when you need a specialized role that doesn't exist in the current roster."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["name", "description", "instructions"],
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "Agent role name (lowercase, hyphenated). e.g., 'data-analyst', 'api-tester'"
        },
        "description" => %{
          "type" => "string",
          "description" => "One-line description of what this agent specializes in."
        },
        "tier" => %{
          "type" => "string",
          "enum" => ["elite", "specialist", "utility"],
          "description" => "Model tier. Default: specialist."
        },
        "instructions" => %{
          "type" => "string",
          "description" => "Full system prompt for the agent. Describe its approach, output format, and boundaries."
        },
        "tools_blocked" => %{
          "type" => "string",
          "description" => "Comma-separated list of tools to block. e.g., 'file_write,shell_execute' for read-only agents."
        }
      }
    }
  end

  @impl true
  def execute(args) do
    name = Map.get(args, "name", "") |> String.trim() |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "-")
    description = Map.get(args, "description", "")
    tier = Map.get(args, "tier", "specialist")
    instructions = Map.get(args, "instructions", "")
    tools_blocked = Map.get(args, "tools_blocked", "")

    if name == "" or instructions == "" do
      {:ok, "Error: name and instructions are required to create an agent."}
    else
      # Parse tools_blocked
      blocked_list =
        if tools_blocked == "" do
          "[]"
        else
          items = tools_blocked |> String.split(",") |> Enum.map(&("\"#{String.trim(&1)}\"")) |> Enum.join(", ")
          "[#{items}]"
        end

      # Build AGENT.md content
      content = """
      ---
      name: #{name}
      description: #{description}
      tier: #{tier}
      tools_blocked: #{blocked_list}
      ---

      #{instructions}
      """
      |> String.trim()

      # Write to ~/.osa/agents/
      agents_dir = Path.expand("~/.osa/agents/#{name}")
      agent_file = Path.join(agents_dir, "AGENT.md")

      try do
        File.mkdir_p!(agents_dir)
        File.write!(agent_file, content)

        # Reload registry to pick up the new agent
        AgentRegistry.load()

        Logger.info("[CreateAgent] Created agent '#{name}' at #{agent_file}")
        {:ok, "Created agent '#{name}' (#{tier}). It's now available for delegation with `delegate(role: \"#{name}\", ...)`"}
      rescue
        e ->
          {:ok, "Failed to create agent: #{Exception.message(e)}"}
      end
    end
  end
end
