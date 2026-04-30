defmodule OptimalSystemAgent.Agent.SkillBootstrap do
  @moduledoc "Create a skill and immediately run it in a fresh session."
  require Logger

  alias OptimalSystemAgent.Tools.Registry

  def create_and_run(params) do
    name = params["name"]
    description = params["description"]
    instructions = params["instructions"]
    triggers = params["triggers"] || [name]
    tools = params["tools"] || []

    skills_dir =
      Path.expand(Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills"))

    dir = Path.join(skills_dir, name)
    path = Path.join(dir, "SKILL.md")

    triggers_yaml = Enum.map_join(triggers, "\n", fn t -> "  - #{t}" end)
    tools_yaml = Enum.map_join(tools, "\n", fn t -> "  - #{t}" end)

    content = """
    ---
    name: #{name}
    description: #{description}
    triggers:
    #{triggers_yaml}
    tools:
    #{tools_yaml}
    ---

    #{instructions}
    """

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, content) do
      Registry.reload_skills()

      session_id = "skill-bootstrap:#{System.unique_integer([:positive])}"
      trigger_message = "#{name}: execute skill"

      {:ok, %{skill_name: name, session_id: session_id, trigger_message: trigger_message}}
    else
      {:error, reason} -> {:error, "Failed to create skill: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def list_self_skills do
    skills_dir =
      Path.expand(Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills"))

    if File.dir?(skills_dir) do
      skills_dir
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(skills_dir, &1)))
      |> Enum.filter(&File.exists?(Path.join([skills_dir, &1, "SKILL.md"])))
      |> Enum.map(fn name ->
        skill = Registry.get_skill(name)
        %{name: name, description: (skill && skill[:description]) || ""}
      end)
    else
      []
    end
  rescue
    _ -> []
  end
end
