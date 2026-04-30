defmodule OptimalSystemAgent.Agent.SkillEvolution do
  @moduledoc "Track and trigger skill evolution from patterns."
  require Logger

  alias OptimalSystemAgent.Memory.SkillGenerator

  def list_evolved_skills do
    skills_dir =
      Path.expand(Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills"))

    if File.dir?(skills_dir) do
      skills_dir
      |> Path.join("**/SKILL.md")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        case File.read(path) do
          {:ok, content} -> String.contains?(content, "source: auto:")
          _ -> false
        end
      end)
      |> Enum.map(fn path -> Path.basename(Path.dirname(path)) end)
    else
      []
    end
  rescue
    _ -> []
  end

  def stats do
    evolved = list_evolved_skills()
    {:ok, %{evolved_count: length(evolved), last_evolution: nil}}
  rescue
    _ -> {:ok, %{evolved_count: 0, last_evolution: nil}}
  end

  def trigger_evolution(_session_id, _failure_info) do
    Logger.info("[SkillEvolution] Triggering evolution from mature patterns")

    case SkillGenerator.generate_all_pending() do
      {:ok, count} ->
        Logger.info("[SkillEvolution] Generated #{count} new skill(s)")
        {:ok, count}

      error ->
        error
    end
  rescue
    e ->
      Logger.warning("[SkillEvolution] Evolution failed: #{Exception.message(e)}")
      {:ok, 0}
  end
end
