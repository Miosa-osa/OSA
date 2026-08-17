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
  alias OptimalSystemAgent.Agent.ActiveSkills
  alias OptimalSystemAgent.Events.Bus

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
      %{path: path} = skill when is_binary(path) -> preview(skill, path)
      nil -> {:error, "Skill '#{name}' not found. Call list_skills to inspect the catalog."}
      _ -> {:error, "Skill '#{name}' has no readable SKILL.md path."}
    end
  end

  def execute(_), do: {:error, "skill_view preview requires a non-empty skill name"}

  @impl true
  def execute(%{"name" => name}, ctx) when is_binary(name) and name != "" do
    case Registry.get_skill(name) do
      nil ->
        {:error, "Skill '#{name}' not found. Call list_skills to inspect the catalog."}

      %{path: path} = skill when is_binary(path) ->
        load(skill, path, ctx)

      _skill ->
        {:error, "Skill '#{name}' has no readable SKILL.md path."}
    end
  end

  def execute(_, _ctx), do: {:error, "skill_view requires a non-empty skill name"}

  defp load(skill, path, ctx) do
    started = System.monotonic_time(:microsecond)
    session_id = Map.get(ctx, :session_id)
    reload? = is_binary(session_id) and skill.name in ActiveSkills.list(session_id)

    cond do
      not SkillLoader.within_roots?(path) ->
        {:error, "Skill path is outside the configured skill roots."}

      SkillLoader.disabled?(path) ->
        {:error, "Skill '#{skill.name}' is disabled."}

      true ->
        case SkillLoader.load_body(path) do
          {:ok, body} ->
            SkillUsage.record_use(skill.name)

            case checkpoint_selection(ctx, skill.name) do
              :ok ->
                emit_selected(ctx, skill.name)

                :telemetry.execute(
                  [:osa, :skills, :selected],
                  %{
                    count: 1,
                    body_bytes: byte_size(body),
                    duration_us: System.monotonic_time(:microsecond) - started,
                    persistence_failed: 0
                  },
                  %{skill: skill.name, session_id: session_id, reload: reload?}
                )

                {:ok,
                 "# Active Skill: #{skill.name}\n\n" <>
                   "You selected this skill for the current task. Follow these instructions " <>
                   "before continuing.\n\n#{String.trim(body)}"}

              {:error, reason} ->
                :telemetry.execute(
                  [:osa, :skills, :selected],
                  %{
                    count: 0,
                    body_bytes: byte_size(body),
                    duration_us: System.monotonic_time(:microsecond) - started,
                    persistence_failed: 1
                  },
                  %{skill: skill.name, session_id: session_id, reload: reload?}
                )

                {:error,
                 "Loaded '#{skill.name}' but could not checkpoint its selection: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, "Could not load '#{skill.name}': #{inspect(reason)}"}
        end
    end
  end

  defp checkpoint_selection(%{session_id: session_id}, skill_name)
       when is_binary(session_id) and session_id != "",
       do: ActiveSkills.select(session_id, skill_name)

  defp checkpoint_selection(_ctx, _skill_name), do: {:error, :missing_session_id}

  defp emit_selected(%{session_id: session_id}, skill_name)
       when is_binary(session_id) and session_id != "" do
    payload = %{type: :skill_selected, skill: skill_name, session_id: session_id}
    Bus.emit(:skill_selected, payload)

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event, payload}
    )

    :ok
  rescue
    _ -> :ok
  end

  defp emit_selected(_ctx, _skill_name), do: :ok

  defp preview(skill, path) do
    cond do
      not SkillLoader.within_roots?(path) ->
        {:error, "Skill path is outside the configured skill roots."}

      SkillLoader.disabled?(path) ->
        {:error, "Skill '#{skill.name}' is disabled."}

      true ->
        case SkillLoader.load_body(path) do
          {:ok, body} ->
            {:ok,
             "# Skill Preview: #{skill.name}\n\n" <>
               "This direct preview has no owning session and did not activate the skill. " <>
               "Runtime agents activate it through the session-aware tool path.\n\n#{String.trim(body)}"}

          {:error, reason} ->
            {:error, "Could not preview '#{skill.name}': #{inspect(reason)}"}
        end
    end
  end
end
