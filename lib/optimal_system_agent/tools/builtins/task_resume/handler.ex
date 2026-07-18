defmodule OptimalSystemAgent.Tools.Builtins.TaskResume.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `task_resume`.

  The mirror of `TaskStop.Handler`. A stopped Loop is terminated (task_stop calls
  `Loop.cancel/1`), so "resume" means re-dispatching the run: the prior `task`
  and a tail of its transcript (both persisted in `RunStore`) are re-seeded into a
  fresh subagent started via `Orchestrator.run_background/2`. That path returns
  immediately, streams the standard lifecycle events, and re-enters the parent
  Loop on completion.

  Split mirrors `TaskStop.Handler`:
    * `validate/2`          — type-checks input shape (cheap, no I/O)
    * `check_permissions/2` — always allow (dispatch is session-local)
    * `execute/2`           — looks the run up in RunStore and re-dispatches it
  """

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Orchestrator
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
  def execute(%{"agent_id" => agent_id} = input, ctx) do
    case RunStore.get(agent_id) do
      nil ->
        {:ok, "No task found for #{agent_id}. Nothing to resume."}

      %{status: :running} = run ->
        if alive?(agent_id) do
          {:ok, "Agent #{agent_id} is still running — nothing to resume."}
        else
          # A stale :running row (process gone) — safe to re-dispatch.
          do_resume(run, ctx, input)
        end

      run ->
        do_resume(run, ctx, input)
    end
  rescue
    e -> {:error, "Failed to resume agent: #{Exception.message(e)}"}
  end

  def execute(_input, _ctx), do: {:error, "Missing required parameter: agent_id"}

  # ── Private ────────────────────────────────────────────────────────────

  # WS7 — full-context resume (CC resumeAgent parity). The orchestrator replays
  # the child's saved message history (unresolved tool_uses filtered, worktree
  # restored when it still exists) under the ORIGINAL agent id, so the resumed
  # agent cites its own earlier findings. Pre-WS7 runs with no saved messages
  # fall back to a legacy task + transcript-tail re-seed inside
  # `Orchestrator.resume_subagent/2`.
  defp do_resume(run, _ctx, input) do
    case Orchestrator.resume_subagent(run.agent_id, resume_message(run, input)) do
      {:ok, agent_id} ->
        {:ok,
         "Resumed #{agent_id} (role=#{run.role}) with its prior transcript restored. " <>
           "Running in the background; it will report back on completion."}

      {:error, reason} ->
        {:ok, "Cannot resume #{run.agent_id}: #{reason}"}
    end
  end

  # Optional "message" param carries follow-up instructions (SendMessage-style
  # continue); default asks the agent to pick up its original task.
  defp resume_message(run, input) do
    case Map.get(input, "message") do
      m when is_binary(m) and m != "" ->
        m

      _ ->
        "Continue the task you were working on. Original task:\n#{run.task}\n\n" <>
          "Pick up where your transcript left off and finish."
    end
  end

  defp alive?(agent_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  rescue
    _ -> false
  end
end
