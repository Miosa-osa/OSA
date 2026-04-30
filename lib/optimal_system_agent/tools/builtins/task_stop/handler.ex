defmodule OptimalSystemAgent.Tools.Builtins.TaskStop.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `task_stop`.

  Split mirrors `FileRead.Handler`:
    * `validate/2`          — type-checks input shape (cheap, no I/O)
    * `check_permissions/2` — always allow (cancellation is session-local)
    * `execute/2`           — looks up the agent in SessionRegistry and cancels it
  """

  alias OptimalSystemAgent.Agent.Loop
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
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) do
      [{_pid, _}] ->
        Loop.cancel(agent_id)
        {:ok, "Agent #{agent_id} cancelled."}

      [] ->
        {:ok, "Agent #{agent_id} not found or already completed."}
    end
  rescue
    e -> {:error, "Failed to stop agent: #{Exception.message(e)}"}
  end

  def execute(_input, _ctx), do: {:error, "Missing required parameter: agent_id"}
end
