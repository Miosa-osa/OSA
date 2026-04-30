defmodule OptimalSystemAgent.Tools.Builtins.CreateSkill.Handler do
  @moduledoc """
  Validation and execution logic for `create_skill`.

    * `validate/2`   — type-check the input shape
    * `execute/2`    — write the SKILL.md file and reload the registry
  """

  alias OptimalSystemAgent.Tools.Builtins.CreateSkill.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(
        %{"name" => name, "description" => desc, "trigger" => trigger, "instructions" => instr} =
          input,
        _ctx
      )
      when is_binary(name) and is_binary(desc) and is_binary(trigger) and is_binary(instr),
      do: {:ok, input}

  def validate(%{"name" => _, "description" => _, "trigger" => _, "instructions" => _}, _ctx),
    do: {:error, "name, description, trigger, and instructions must all be strings", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: name, description, trigger, instructions", -32_602}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(
        %{
          "name" => skill_name,
          "description" => desc,
          "trigger" => trigger,
          "instructions" => instructions
        } = args,
        _ctx
      ) do
    tags = args["tags"] || []

    skills_dir =
      Application.get_env(:optimal_system_agent, :skills_dir, Constants.default_skills_dir())
      |> Path.expand()

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
