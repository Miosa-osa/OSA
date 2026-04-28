defmodule OptimalSystemAgent.Tools.Builtins.ListSkills do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @impl true
  def safety, do: :read_safe

  @impl true
  def name, do: "list_skills"

  @impl true
  def description, do: "List all available skills with their descriptions and triggers."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end

  @impl true
  def execute(_args) do
    skills_dir =
      Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills") |> Path.expand()

    case File.ls(skills_dir) do
      {:ok, entries} ->
        skills =
          entries
          |> Enum.sort()
          |> Enum.flat_map(fn entry ->
            skill_path = Path.join([skills_dir, entry, "SKILL.md"])

            if File.exists?(skill_path) do
              case File.read(skill_path) do
                {:ok, content} ->
                  desc = extract_field(content, "description") || "No description"
                  trigger = extract_field(content, "trigger") || "none"
                  source = extract_field(content, "source") || "manual"
                  [{entry, desc, trigger, source}]

                _ ->
                  []
              end
            else
              []
            end
          end)

        if skills == [] do
          {:ok,
           "No skills found. Use create_skill to create one, or skills auto-generate as you work."}
        else
          formatted =
            skills
            |> Enum.with_index(1)
            |> Enum.map(fn {{skill_name, desc, trigger, source}, idx} ->
              "#{idx}. #{skill_name} — #{desc}\n   Trigger: #{trigger} (#{source})"
            end)
            |> Enum.join("\n\n")

          {:ok, "Available skills (#{length(skills)}):\n\n#{formatted}"}
        end

      {:error, :enoent} ->
        File.mkdir_p(skills_dir)
        {:ok, "No skills found. Skills directory created. Use create_skill to add skills."}

      {:error, reason} ->
        {:error, "Failed to list skills: #{inspect(reason)}"}
    end
  end

  defp extract_field(content, field) do
    case Regex.run(~r/#{field}:\s*"?([^"\n]+)"?/, content) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end
end
