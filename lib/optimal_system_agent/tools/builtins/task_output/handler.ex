defmodule OptimalSystemAgent.Tools.Builtins.TaskOutput.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `task_output`.

  Split mirrors `FileRead.Handler`:
    * `validate/2`          — type-checks input shape (cheap, no I/O)
    * `check_permissions/2` — always allow (reads are session-local, no side effects)
    * `execute/2`           — looks up the agent in SessionRegistry and reports state
  """

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"agent_id" => agent_id} = input, _ctx) when is_binary(agent_id),
    do: {:ok, input}

  def validate(%{"agent_id" => _}, _ctx),
    do: {:error, "agent_id must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: agent_id", -32_602}

  # ── Stage 2: Permission check ──────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"agent_id" => agent_id}, _ctx) do
    case RunStore.get(agent_id) do
      nil -> live_output(agent_id)
      run -> {:ok, format_run(run)}
    end
  rescue
    e -> {:error, "Failed to get task output: #{Exception.message(e)}"}
  end

  def execute(_input, _ctx), do: {:error, "Missing required parameter: agent_id"}

  defp live_output(agent_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) do
      [{_pid, _}] ->
        case Loop.get_state(agent_id) do
          {:ok, state} ->
            iter = state[:iteration_count] || state[:iteration] || 0
            tokens = state[:estimated_tokens] || 0
            status = state[:status] || :unknown

            {:ok,
             "Agent #{agent_id} is #{status}.\n" <>
               "- Iterations: #{iter}\n" <>
               "- Tokens used: #{tokens}\n" <>
               "- Status: running"}

          _ ->
            {:ok, "Agent #{agent_id} is running (state unavailable)."}
        end

      [] ->
        {:ok, "Agent #{agent_id} is not running. It may have completed or was never started."}
    end
  end

  defp format_run(%{result: result} = run) when is_map(result) do
    RunStore.format_result(result) <>
      "\n\nStatus: #{run.status}\nStarted: #{DateTime.to_iso8601(run.started_at)}"
  end

  defp format_run(run) do
    """
    Agent #{run.agent_id} is #{run.status}.
    - Phase: #{Map.get(run, :phase, :unknown)}
    - Current action: #{Map.get(run, :current_action) || "none"}
    - Role: #{run.role}
    - Parent: #{run.parent_session_id}
    - Tools: #{run.tool_count}
    - Tokens: #{run.tokens_used}
    - Last heartbeat: #{format_datetime(Map.get(run, :last_heartbeat_at))}
    - Transcript: #{run.transcript_path}
    """
    |> String.trim()
  end

  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_datetime(_), do: "unknown"
end
