defmodule OptimalSystemAgent.Tools.Builtins.SkillView do
  @moduledoc """
  Load one installed SKILL.md into the owning agent's context.

  This is the second tier of skill progressive disclosure. The system prompt
  carries only a compact name and description catalog. The agent selects one
  relevant skill, then this read-only tool returns its full instructions as a
  normal tool result so the same agent can apply them to the current task.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Registry
  alias OptimalSystemAgent.Tools.Registry.{SkillLoader, SkillUsage}

  @impl true
  def name, do: "skill_view"

  @impl true
  def description do
    "Load the full instructions for one skill selected from the compact skill catalog. " <>
      "Call this before acting when a listed skill is relevant to the current task."
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def search_hint,
    do: "load read inspect apply skill SKILL.md instructions workflow procedure"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "Exact skill name from the Skills catalog"
        }
      },
      "required" => ["name"]
    }
  end

  @impl true
  def execute(%{"name" => name}) when is_binary(name) and name != "" do
    case Registry.get_skill(name) do
      nil ->
        {:error, "Skill '#{name}' not found. Call list_skills to inspect the catalog."}

      %{path: path} = skill when is_binary(path) ->
        load(skill, path)

      _skill ->
        {:error, "Skill '#{name}' has no readable SKILL.md path."}
    end
  end

  def execute(_), do: {:error, "skill_view requires a non-empty skill name"}

  defp load(skill, path) do
    cond do
      not SkillLoader.within_roots?(path) ->
        {:error, "Skill path is outside the configured skill roots."}

      SkillLoader.disabled?(path) ->
        {:error, "Skill '#{skill.name}' is disabled."}

      true ->
        case SkillLoader.load_body(path) do
          {:ok, body} ->
            SkillUsage.record_use(skill.name)

            {:ok,
             "# Active Skill: #{skill.name}\n\n" <>
               "You selected this skill for the current task. Follow these instructions " <>
               "before continuing.\n\n#{String.trim(body)}"}

          {:error, reason} ->
            {:error, "Could not load '#{skill.name}': #{inspect(reason)}"}
        end
    end
  end
end
