defmodule OptimalSystemAgent.Agent.ActiveSkills do
  @moduledoc """
  Durable record of the skills selected by an agent for a session.

  Skill bodies are loaded progressively and remain outside the permanent system
  prompt. This store records only their names. The context builder rehydrates
  those names on every generation, so compaction cannot make the agent forget
  which operating instructions it deliberately selected.
  """

  require Logger

  alias OptimalSystemAgent.Agent.SessionPersistence.RecordLock
  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.System.AtomicFile
  alias OptimalSystemAgent.Tools.Registry

  @max_skills 12

  @spec select(String.t(), String.t()) :: :ok | {:error, term()}
  def select(session_id, skill_name)
      when is_binary(session_id) and session_id != "" and is_binary(skill_name) and
             skill_name != "" do
    mutate(session_id, fn names ->
      names
      |> Enum.reject(&(&1 == skill_name))
      |> Kernel.++([skill_name])
      |> Enum.take(-@max_skills)
    end)
  end

  @spec list(String.t()) :: [String.t()]
  def list(session_id) when is_binary(session_id) do
    case load(session_id) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end

  @spec load(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def load(session_id) when is_binary(session_id) do
    case File.read(path(session_id)) do
      {:ok, bytes} -> decode(bytes)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(session_id) when is_binary(session_id), do: File.rm(path(session_id)) |> absent_ok()

  @spec exists?(String.t()) :: boolean()
  def exists?(session_id) when is_binary(session_id), do: File.exists?(path(session_id))

  @spec context_block(String.t(), [map()]) :: String.t() | nil
  def context_block(session_id, messages \\ []) when is_binary(session_id) do
    case load(session_id) do
      {:ok, []} ->
        nil

      {:ok, names} ->
        missing = Enum.reject(names, &body_present?(messages, &1))

        reload =
          case missing do
            [] ->
              "Their instruction bodies are present in the current conversation."

            _ ->
              calls = Enum.map_join(missing, ", ", &"`skill_view` for `#{&1}`")

              "Their instruction bodies are absent, likely because of compaction or restart. " <>
                "Before any further task action, reload #{calls}."
          end

        "## Selected Skills\n\n" <>
          "These skills remain active for this task across compaction and restart. " <>
          reload <> "\n\n" <> Enum.map_join(names, "\n", &"- **#{&1}**")

      {:error, reason} ->
        Logger.error("[active_skills] checkpoint unavailable: #{inspect(reason)}")

        "## Selected Skills Checkpoint Error\n\n" <>
          "OSA could not restore the selected-skill checkpoint (#{bounded(reason)}). " <>
          "Do not continue the task until the skill is selected again with `skill_view`."
    end
  end

  defp mutate(session_id, fun) do
    record_path = path(session_id)

    case RecordLock.with_lock_strict(record_path, fn ->
           names =
             case load(session_id) do
               {:ok, loaded} ->
                 loaded

               {:error, reason} ->
                 Logger.warning(
                   "[active_skills] rebuilding unreadable checkpoint while selecting a skill: " <>
                     inspect(reason)
                 )

                 []
             end

           AtomicFile.write(record_path, Jason.encode!(%{version: 1, skills: fun.(names)}))
         end) do
      {:ok, result} -> result
      {:error, :contended} -> {:error, :contended}
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"skills" => names}} when is_list(names) ->
        {:ok,
         names
         |> Enum.filter(&(is_binary(&1) and &1 != ""))
         |> Enum.uniq()
         |> Enum.take(-@max_skills)}

      {:ok, invalid} ->
        {:error, {:invalid_structure, invalid}}

      {:error, reason} ->
        {:error, {:invalid_json, Exception.message(reason)}}
    end
  end

  defp body_present?(messages, skill_name) do
    with {:ok, body} <- Registry.load_skill_body(skill_name) do
      expected = String.trim(body)

      Enum.any?(messages, fn message ->
        role = Map.get(message, :role) || Map.get(message, "role")
        content = Map.get(message, :content) || Map.get(message, "content") || ""

        role == "tool" and is_binary(content) and expected != "" and
          String.contains?(content, expected)
      end)
    else
      _ -> false
    end
  end

  defp bounded(reason),
    do: reason |> inspect(limit: 5, printable_limit: 120) |> String.slice(0, 160)

  defp path(session_id) do
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
    Path.join([ConfigFile.config_dir(), "sessions", "#{safe_id}.skills"])
  end

  defp absent_ok(:ok), do: :ok
  defp absent_ok({:error, :enoent}), do: :ok
  defp absent_ok(error), do: error
end
