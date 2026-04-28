defmodule OptimalSystemAgent.Tools.Builtins.CreateSkill do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @impl true
  def safety, do: :write_safe

  @impl true
  def deferred?, do: true

  @impl true
  def name, do: "create_skill"

  @impl true
  def description,
    do:
      "Create a reusable skill document. Skills load automatically and help perform similar tasks faster in the future."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "Kebab-case skill name (e.g. 'express-api-testing')"
        },
        "description" => %{"type" => "string", "description" => "What this skill helps with"},
        "trigger" => %{
          "type" => "string",
          "description" => "Keywords or regex for when to activate (e.g. 'express|rest api|jest')"
        },
        "instructions" => %{
          "type" => "string",
          "description" => "Step-by-step instructions for the skill"
        },
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Tags for categorization"
        }
      },
      "required" => ["name", "description", "trigger", "instructions"]
    }
  end

  @impl true
  def execute(
        %{
          "name" => skill_name,
          "description" => desc,
          "trigger" => trigger,
          "instructions" => instructions
        } = args
      ) do
    tags = args["tags"] || []

    skills_dir =
      Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills") |> Path.expand()

    skill_dir = Path.join(skills_dir, skill_name)
    skill_path = Path.join(skill_dir, "SKILL.md")

    tags_str = Enum.map_join(tags, ", ", &"\"#{&1}\"")

    content =
      """
      ---
      name: #{skill_name}
      description: #{desc}
      trigger: "#{trigger}"
      tags: [#{tags_str}]
      source: manual
      ---

      ## Instructions

      #{instructions}
      """
      |> String.trim_leading()

    with :ok <- File.mkdir_p(skill_dir),
         :ok <- File.write(skill_path, content) do
      try do
        OptimalSystemAgent.Tools.Registry.reload_skills()
      rescue
        _ -> :ok
      end

      {:ok,
       "Created skill '#{skill_name}' at #{skill_path}\nTrigger: #{trigger}\nActivates automatically on matching tasks."}
    else
      {:error, reason} ->
        {:error, "Failed to create skill: #{inspect(reason)}"}
    end
  end
end
