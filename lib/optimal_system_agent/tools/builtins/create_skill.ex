defmodule OptimalSystemAgent.Tools.Builtins.CreateSkill do
  @moduledoc """
  Dynamic skill creation — writes a SKILL.md file and registers it immediately.

  Use this tool when the agent needs a capability that doesn't exist yet.
  The tool creates a markdown-defined skill file at ~/.osa/skills/<name>/SKILL.md
  with YAML frontmatter and instruction body. The Tools.Registry picks it up
  on next reload.

  This enables OSA to grow its own capabilities at runtime, teaching itself
  new skills as the situation demands.
  """
  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  @impl true
  def name, do: "create_skill"

  @impl true
  def description do
    "Dynamically create a new skill for the agent. " <>
      "Use when you need a capability that doesn't exist yet — writes a SKILL.md file and registers it immediately."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "Skill name (kebab-case, e.g., 'data-analyzer')"
        },
        "description" => %{
          "type" => "string",
          "description" => "What this skill does (shown to the LLM for tool selection)"
        },
        "instructions" => %{
          "type" => "string",
          "description" => "Detailed instructions for how to execute this skill"
        },
        "tools" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Tools this skill needs (shell_execute, file_read, file_write, web_search, memory_save)"
        },
        "force" => %{
          "type" => "boolean",
          "description" =>
            "Bypass skill discovery and force creation of a new skill even if similar ones exist (default: false)"
        }
      },
      "required" => ["name", "description", "instructions"]
    }
  end

  @impl true
  def execute(%{"name" => name, "description" => desc, "instructions" => instructions} = params) do
    tools = params["tools"] || []
    force = params["force"] || false

    # Validate name format
    unless Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name) do
      {:error,
       "Skill name must be kebab-case (lowercase letters, numbers, hyphens, underscores). Got: #{name}"}
    else
      # Unless force=true, check for existing matching skills first
      if not force do
        case OptimalSystemAgent.Agent.Orchestrator.find_matching_skills(desc) do
          {:matches, matches} ->
            high_relevance = Enum.filter(matches, fn m -> m.relevance > 0.5 end)

            if high_relevance != [] do
              match_list =
                Enum.map_join(high_relevance, "\n", fn m ->
                  "  - #{m.name}: #{m.description} (relevance: #{m.relevance})"
                end)

              {:ok,
               "Found existing skills that may match:\n#{match_list}\n\n" <>
                 "Use one of these existing skills, or call create_skill again with \"force\": true to create '#{name}' anyway."}
            else
              do_create(name, desc, instructions, tools)
            end

          :no_matches ->
            do_create(name, desc, instructions, tools)
        end
      else
        Logger.info("[CreateSkill] Force-creating skill: #{name} (bypassing discovery)")
        do_create(name, desc, instructions, tools)
      end
    end
  end

  def execute(_), do: {:error, "Missing required parameters: name, description, instructions"}

  # ── Private ──────────────────────────────────────────────────────

  defp do_create(name, desc, instructions, tools) do
    Logger.info("[CreateSkill] Creating skill: #{name}")

    try do
      case OptimalSystemAgent.Agent.Orchestrator.create_skill(name, desc, instructions, tools) do
        {:ok, _} ->
          {:ok,
           "Skill '#{name}' created and registered successfully at ~/.osa/skills/#{name}/SKILL.md. It is now available for use."}

        {:error, reason} ->
          {:error, "Failed to create skill: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("[CreateSkill] Exception: #{Exception.message(e)}")
        {:error, "Failed to create skill: #{Exception.message(e)}"}
    end
  end
end
