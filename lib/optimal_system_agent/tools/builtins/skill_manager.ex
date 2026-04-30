defmodule OptimalSystemAgent.Tools.Builtins.SkillManager do
  @moduledoc """
  Skill lifecycle management tool — list, search, create, enable, disable, delete, reload.

  Superset of `create_skill`. Provides the LLM with full CRUD over the skill
  system so it can manage its own capabilities. All disk I/O the model can't
  do alone is handled here; the decision of *when* to create skills is left to
  model intelligence via SYSTEM.md instructions.
  """
  @behaviour MiosaTools.Behaviour

  require Logger

  alias OptimalSystemAgent.Tools.Registry

  defp skills_dir, do: Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills")

  @impl true
  def name, do: "skill_manager"

  @impl true
  def description do
    "Manage custom skills: list, search, create, enable, disable, delete, or reload. " <>
      "Use this to extend your capabilities by creating reusable skills from repeating patterns."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["list", "search", "create", "enable", "disable", "delete", "reload"],
          "description" => "Action to perform"
        },
        "name" => %{
          "type" => "string",
          "description" => "Skill name (for create/enable/disable/delete)"
        },
        "query" => %{
          "type" => "string",
          "description" => "Search query (for search action)"
        },
        "description" => %{
          "type" => "string",
          "description" => "Skill description (for create)"
        },
        "instructions" => %{
          "type" => "string",
          "description" => "Skill instructions/prompt (for create)"
        },
        "tools" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Tools this skill needs (for create)"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def execute(%{"action" => "list"}) do
    dir = Path.expand(skills_dir())

    custom_skills =
      if File.dir?(dir) do
        dir
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.map(fn skill_name ->
          disabled? = File.exists?(Path.join([dir, skill_name, ".disabled"]))
          status = if disabled?, do: "disabled", else: "active"
          "  #{String.pad_trailing(skill_name, 24)} [#{status}]"
        end)
      else
        []
      end

    builtin_tools = Registry.list_tools_direct()

    builtin_section =
      Enum.map_join(builtin_tools, "\n", fn tool ->
        "  #{String.pad_trailing(tool.name, 24)} [built-in]"
      end)

    custom_section =
      if custom_skills == [] do
        "  (none)"
      else
        Enum.join(custom_skills, "\n")
      end

    {:ok,
     "Built-in tools (#{length(builtin_tools)}):\n#{builtin_section}\n\n" <>
       "Custom skills (#{length(custom_skills)}):\n#{custom_section}"}
  end

  def execute(%{"action" => "search", "query" => query}) when is_binary(query) do
    results = Registry.search(query)

    if results == [] do
      {:ok, "No skills match '#{query}'."}
    else
      formatted =
        Enum.map_join(results, "\n", fn {name, desc, score} ->
          "  #{String.pad_trailing(name, 20)} #{Float.round(score, 2)} — #{String.slice(desc, 0, 60)}"
        end)

      {:ok, "Matching skills (#{length(results)}):\n#{formatted}"}
    end
  end

  def execute(%{"action" => "search"}) do
    {:error, "search action requires a 'query' parameter"}
  end

  def execute(
        %{
          "action" => "create",
          "name" => name,
          "description" => desc,
          "instructions" => instructions
        } = params
      ) do
    tools = params["tools"] || []

    unless Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name) do
      {:error,
       "Skill name must be kebab-case (lowercase, numbers, hyphens, underscores). Got: #{name}"}
    else
      do_create_skill(name, desc, instructions, tools)
    end
  end

  def execute(%{"action" => "create"}) do
    {:error, "create action requires: name, description, instructions"}
  end

  def execute(%{"action" => "enable", "name" => name}) do
    marker = Path.join([Path.expand(skills_dir()), name, ".disabled"])

    if File.exists?(marker) do
      File.rm(marker)
      Registry.reload_skills()
      {:ok, "Skill '#{name}' enabled and registry reloaded."}
    else
      {:ok, "Skill '#{name}' is already enabled."}
    end
  end

  def execute(%{"action" => "enable"}) do
    {:error, "enable action requires a 'name' parameter"}
  end

  def execute(%{"action" => "disable", "name" => name}) do
    skill_dir = Path.join(Path.expand(skills_dir()), name)
    marker = Path.join(skill_dir, ".disabled")

    if File.dir?(skill_dir) do
      File.write!(marker, "disabled at #{DateTime.utc_now() |> DateTime.to_iso8601()}")
      Registry.reload_skills()
      {:ok, "Skill '#{name}' disabled."}
    else
      {:error, "Skill '#{name}' not found in #{skills_dir()}."}
    end
  end

  def execute(%{"action" => "disable"}) do
    {:error, "disable action requires a 'name' parameter"}
  end

  def execute(%{"action" => "delete", "name" => name}) do
    skill_dir = Path.join(Path.expand(skills_dir()), name)

    if File.dir?(skill_dir) do
      File.rm_rf!(skill_dir)
      Registry.reload_skills()
      {:ok, "Skill '#{name}' deleted from #{skills_dir()}/#{name}/."}
    else
      {:error, "Skill '#{name}' not found."}
    end
  end

  def execute(%{"action" => "delete"}) do
    {:error, "delete action requires a 'name' parameter"}
  end

  def execute(%{"action" => "reload"}) do
    Registry.reload_skills()
    tools = Registry.list_tools_direct()
    {:ok, "Skills reloaded. #{length(tools)} tools now available."}
  end

  def execute(%{"action" => action}) do
    {:error,
     "Unknown action: #{action}. Valid: list, search, create, enable, disable, delete, reload"}
  end

  def execute(_) do
    {:error, "Missing required parameter: action"}
  end

  # ── Private ─────────────────────────────────────────────────────

  defp do_create_skill(name, desc, instructions, tools) do
    dir = Path.join(Path.expand(skills_dir()), name)
    file = Path.join(dir, "SKILL.md")

    if File.exists?(file) do
      {:error,
       "Skill '#{name}' already exists at #{file}. Delete it first or use a different name."}
    else
      File.mkdir_p!(dir)

      tools_yaml =
        if tools == [] do
          ""
        else
          "tools:\n" <> Enum.map_join(tools, "\n", fn t -> "  - #{t}" end) <> "\n"
        end

      content = """
      ---
      name: #{name}
      description: #{desc}
      #{tools_yaml}---

      #{instructions}
      """

      File.write!(file, content)

      Logger.info("[SkillManager] Created skill: #{name} at #{file}")

      Registry.reload_skills()
      {:ok, "Skill '#{name}' created at #{file} and registered."}
    end
  rescue
    e ->
      Logger.error("[SkillManager] Create failed: #{Exception.message(e)}")
      {:error, "Failed to create skill: #{Exception.message(e)}"}
  end
end
