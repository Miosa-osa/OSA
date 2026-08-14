defmodule OptimalSystemAgent.Tools.Builtins.UseSkill do
  @moduledoc """
  Invoke a named skill from the skill registry.

  Loads the skill's SKILL.md instruction body and executes it through the
  agent loop with the supplied task description injected as `{{task}}`.

  Use this tool when:
  - You know a skill exists (from `list_skills` or context injection) and
    want to explicitly run it for a specific task.
  - You want to compose skills together sequentially.

  The skill's full instruction set becomes the system-level context for a
  single-turn inner LLM call, so the result is already processed output —
  not raw SKILL.md text.
  """
  @behaviour MiosaTools.Behaviour

  require Logger

  alias OptimalSystemAgent.Orchestrator
  alias OptimalSystemAgent.Skills.Frontmatter
  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Tools.Registry.SkillLoader

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  # Deferred: absent from the default toolbox, discovered mid-turn via
  # `tool_search`. Reason: paired with skill_manager; discovered together when skills are in play.
  #
  # Every schema in the default set is re-sent on EVERY request. Measured
  # across 15 SWE-bench Pro transcripts, this tool was called zero times while
  # costing its schema on all 863 turns.
  @impl true
  def should_defer?, do: true

  @impl true
  def name, do: "use_skill"

  @impl true
  def description do
    "Invoke a named skill by running its instruction set with a specific task. " <>
      "Use when you want to explicitly apply a skill's specialised capability."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "skill_name" => %{
          "type" => "string",
          "description" => "Name of the skill to invoke (as listed in active skills context)"
        },
        "task" => %{
          "type" => "string",
          "description" => "The specific task or question to process with this skill"
        }
      },
      "required" => ["skill_name", "task"]
    }
  end

  @impl true
  def execute(%{"skill_name" => skill_name, "task" => task} = args) do
    if sid = args["__session_id__"], do: Process.put(:osa_session_id, sid)

    case Tools.get_skill(skill_name) do
      nil ->
        {:error, "Skill '#{skill_name}' not found. Use list_skills to see available skills."}

      skill ->
        run_skill(skill, task)
    end
  end

  def execute(_), do: {:error, "Missing required parameters: skill_name, task"}

  # ── Private ──────────────────────────────────────────────────────────

  defp run_skill(%{path: path} = skill, task) when is_binary(path) do
    cond do
      not SkillLoader.within_roots?(path) ->
        {:error, "path outside skills directory"}

      SkillLoader.disabled?(path) ->
        {:error,
         "Skill '#{skill[:name] || skill.name}' is disabled (a .disabled marker sits beside its SKILL.md)."}

      true ->
        read_and_run(skill, path, task)
    end
  end

  defp run_skill(skill, _task) do
    {:error, "Skill '#{skill.name}' has no file path — cannot load instructions."}
  end

  defp read_and_run(skill, path, task) do
    case File.read(path) do
      {:ok, content} ->
        instructions = Frontmatter.body(content)
        prompt = build_prompt(skill[:name] || skill.name, instructions, task)

        Logger.info(
          "[UseSkill] Invoking skill '#{skill[:name]}' as subagent for task: #{String.slice(task, 0, 80)}"
        )

        run_as_subagent(prompt, skill, task)

      {:error, reason} ->
        {:error, "Could not read skill file at #{path}: #{inspect(reason)}"}
    end
  end

  defp build_prompt(skill_name, instructions, task) do
    """
    You are executing the '#{skill_name}' skill.

    ## Skill Instructions

    #{instructions}

    ## Current Task

    #{task}

    Follow the skill instructions above to complete the task. Be concise and direct.
    """
  end

  defp run_as_subagent(prompt, skill, task) do
    session_id =
      Process.get(:osa_session_id) || OptimalSystemAgent.Agent.SessionId.generate("use_skill")

    tools_allowed =
      case Map.get(skill, :tools, []) do
        list when is_list(list) and list != [] -> list
        _ -> nil
      end

    config = %{
      task: task,
      parent_session_id: session_id,
      role: "skill:#{skill[:name] || "unknown"}",
      tier: :specialist,
      system_prompt: prompt,
      tools_allowed: tools_allowed,
      tools_blocked: ["delegate", "use_skill"],
      max_iterations: 15
    }

    case Orchestrator.run_subagent(config) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "Skill execution failed: #{inspect(reason)}"}
    end
  end
end
