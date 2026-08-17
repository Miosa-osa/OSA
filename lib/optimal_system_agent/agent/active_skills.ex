defmodule OptimalSystemAgent.Agent.ActiveSkills do
  @moduledoc """
  Durable record of the skills selected by an agent for a session.

  Skill bodies are loaded progressively and remain outside the permanent system
  prompt. This store records their names plus a content hash and selection time.
  The context builder rehydrates that identity on every generation, so
  compaction cannot make the agent forget which operating instructions it
  selected and a changed SKILL.md cannot silently replace the selected version.
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
    with {:ok, snapshot} <- snapshot(skill_name) do
      mutate(session_id, fn snapshots ->
        snapshots
        |> Enum.reject(&(&1.name == skill_name))
        |> Kernel.++([snapshot])
        |> Enum.take(-@max_skills)
      end)
    end
  end

  @spec list(String.t()) :: [String.t()]
  def list(session_id) when is_binary(session_id) do
    case snapshots(session_id) do
      {:ok, entries} -> Enum.map(entries, & &1.name)
      {:error, _reason} -> []
    end
  end

  @spec load(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def load(session_id) when is_binary(session_id) do
    case snapshots(session_id) do
      {:ok, entries} -> {:ok, Enum.map(entries, & &1.name)}
      error -> error
    end
  end

  @doc "Load the durable name/hash/version snapshots for a session."
  @spec snapshots(String.t()) :: {:ok, [map()]} | {:error, term()}
  def snapshots(session_id) when is_binary(session_id) do
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
    case snapshots(session_id) do
      {:ok, []} ->
        nil

      {:ok, entries} ->
        names = Enum.map(entries, & &1.name)
        changed = Enum.filter(entries, &changed?/1)
        missing = Enum.reject(entries, &body_present?(messages, &1.name))

        reload =
          cond do
            changed != [] ->
              versions = Enum.map_join(changed, ", ", &"`#{&1.name}`")

              "The installed body changed since selection for #{versions}. " <>
                "Before any further task action, reload " <>
                Enum.map_join(changed, ", ", &"`skill_view` for `#{&1.name}`") <> "."

            missing == [] ->
              "Their instruction bodies are present in the current conversation."

            true ->
              calls = Enum.map_join(missing, ", ", &"`skill_view` for `#{&1.name}`")

              "Their instruction bodies are absent, likely because of compaction or restart. " <>
                "Before any further task action, reload #{calls}."
          end

        block =
          "## Selected Skills\n\n" <>
            "These skills remain active for this task across compaction and restart. " <>
            reload <> "\n\n" <> Enum.map_join(names, "\n", &"- **#{&1}**")

        :telemetry.execute(
          [:osa, :skills, :context],
          %{count: length(entries), bytes: byte_size(block)},
          %{session_id: session_id, reload_required: missing != [] or changed != []}
        )

        block

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
           snapshots =
             case snapshots(session_id) do
               {:ok, loaded} ->
                 loaded

               {:error, reason} ->
                 Logger.warning(
                   "[active_skills] rebuilding unreadable checkpoint while selecting a skill: " <>
                     inspect(reason)
                 )

                 []
             end

           AtomicFile.write(record_path, Jason.encode!(%{version: 2, skills: fun.(snapshots)}))
         end) do
      {:ok, result} -> result
      {:error, :contended} -> {:error, :contended}
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"skills" => entries}} when is_list(entries) ->
        {:ok,
         entries
         |> Enum.map(&decode_entry/1)
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq_by(& &1.name)
         |> Enum.take(-@max_skills)}

      {:ok, invalid} ->
        {:error, {:invalid_structure, invalid}}

      {:error, reason} ->
        {:error, {:invalid_json, Exception.message(reason)}}
    end
  end

  defp decode_entry(name) when is_binary(name) and name != "",
    do: %{name: name, hash: nil, selected_at: nil}

  defp decode_entry(%{"name" => name} = entry) when is_binary(name) and name != "" do
    %{name: name, hash: entry["hash"], selected_at: entry["selected_at"]}
  end

  defp decode_entry(_), do: nil

  defp snapshot(skill_name) do
    case Registry.load_skill_body(skill_name) do
      {:ok, body} ->
        {:ok,
         %{
           name: skill_name,
           hash: body_hash(body),
           selected_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:error, reason} ->
        {:error, {:skill_body_unavailable, skill_name, reason}}
    end
  end

  defp changed?(%{hash: nil}), do: false

  defp changed?(%{name: name, hash: expected}) do
    case Registry.load_skill_body(name) do
      {:ok, body} -> body_hash(body) != expected
      _ -> true
    end
  end

  defp body_hash(body),
    do: :crypto.hash(:sha256, String.trim(body)) |> Base.encode16(case: :lower)

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
