defmodule OptimalSystemAgent.Agent.PersistedResult do
  @moduledoc """
  Persist subagent results so they survive context compaction.

  When a subagent completes, its result is saved to disk so that after a
  context compaction (which may drop the subagent's output from the
  conversation), the parent agent can still retrieve the result.

  Adapted from HackerAI's `persisted-result.ts`.

  ## Storage

  Results are stored as JSON files under `~/.osa/subagent_results/`:
  ```
  ~/.osa/subagent_results/<session_id>/<agent_id>.json
  ```

  Each result contains:
  - agent_id, task, status, verdict
  - evidence_refs, artifacts, limitations, next_steps
  - timestamp, model used, duration

  ## Usage

      # Save a subagent result
      PersistedResult.save("session-123", "agent-456", %{
        task: "Validate SQLi on /api/users",
        status: :completed,
        verdict: :confirmed,
        evidence: ["screenshot.png", "request.txt"]
      })

      # Retrieve after compaction
      {:ok, result} = PersistedResult.load("session-123", "agent-456")

      # List all results for a session
      results = PersistedResult.list("session-123")
  """

  require Logger

  @results_dir "~/.osa/subagent_results"

  @doc "Save a subagent result to disk."
  @spec save(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def save(session_id, agent_id, result) when is_binary(session_id) and is_binary(agent_id) do
    path = result_path(session_id, agent_id)

    enriched =
      Map.merge(result, %{
        agent_id: agent_id,
        session_id: session_id,
        saved_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case File.write(path, Jason.encode!(enriched, pretty: true)) do
          :ok ->
            Logger.debug("[PersistedResult] Saved result for #{agent_id} to #{path}")
            {:ok, path}

          {:error, reason} ->
            {:error, "Failed to write result file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to create results directory: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Failed to save result: #{Exception.message(e)}"}
  end

  @doc "Load a subagent result from disk."
  @spec load(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def load(session_id, agent_id) when is_binary(session_id) and is_binary(agent_id) do
    path = result_path(session_id, agent_id)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, result} -> {:ok, result}
          {:error, _} -> {:error, "Failed to parse result file"}
        end

      {:error, :enoent} ->
        {:error, "No saved result for agent #{agent_id}"}

      {:error, reason} ->
        {:error, "Failed to read result file: #{inspect(reason)}"}
    end
  end

  @doc "List all saved results for a session."
  @spec list(String.t()) :: [map()]
  def list(session_id) when is_binary(session_id) do
    dir = session_dir(session_id)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn file ->
          path = Path.join(dir, file)

          case File.read(path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, result} -> result
                _ -> nil
              end

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  @doc "Delete all saved results for a session."
  @spec clear_session(String.t()) :: :ok
  def clear_session(session_id) when is_binary(session_id) do
    dir = session_dir(session_id)
    File.rm_rf(dir)
    :ok
  end

  @doc "Check if a result exists for an agent."
  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(session_id, agent_id) do
    path = result_path(session_id, agent_id)
    File.exists?(path)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp result_path(session_id, agent_id) do
    Path.join([session_dir(session_id), "#{agent_id}.json"])
  end

  defp session_dir(session_id) do
    Path.expand(Path.join([@results_dir, session_id]))
  end
end
