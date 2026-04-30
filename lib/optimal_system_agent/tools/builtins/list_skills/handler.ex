defmodule OptimalSystemAgent.Tools.Builtins.ListSkills.Handler do
  @moduledoc """
  Validation and execution logic for `list_skills`.

    * `validate/2`  — accepts any input (no required fields)
    * `execute/2`   — scan skills directory, format and return listing
  """

  alias OptimalSystemAgent.Tools.Builtins.ListSkills.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(input, _ctx) when is_map(input), do: {:ok, input}

  def validate(_, _ctx),
    do: {:error, "Input must be a map", -32_602}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(_args, _ctx) do
    skills_dir =
      Application.get_env(:optimal_system_agent, :skills_dir, Constants.default_skills_dir())
      |> Path.expand()

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

  # ── Private ───────────────────────────────────────────────────────────

  defp extract_field(content, field) do
    case Regex.run(~r/#{field}:\s*"?([^"\n]+)"?/, content) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end
end
