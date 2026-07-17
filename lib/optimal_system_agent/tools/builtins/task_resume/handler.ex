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
  def execute(%{"agent_id" => agent_id}, ctx) do
    case RunStore.get(agent_id) do
      nil ->
        {:ok, "No task found for #{agent_id}. Nothing to resume."}

      %{status: :running} = run ->
        if alive?(agent_id) do
          {:ok, "Agent #{agent_id} is still running — nothing to resume."}
        else
          # A stale :running row (process gone) — safe to re-dispatch.
          do_resume(run, ctx)
        end

      run ->
        do_resume(run, ctx)
    end
  rescue
    e -> {:error, "Failed to resume agent: #{Exception.message(e)}"}
  end

  def execute(_input, _ctx), do: {:error, "Missing required parameter: agent_id"}

  # ── Private ────────────────────────────────────────────────────────────

  defp do_resume(run, ctx) do
    parent = run.parent_session_id || (ctx && Map.get(ctx, :session_id))

    if is_binary(parent) and is_binary(run.task) and String.trim(run.task) != "" do
      config = %{
        role: run.role,
        name: handle_of(run.agent_id),
        task: resume_task(run)
      }

      {:ok, new_id} = Orchestrator.run_background(parent, config)

      {:ok,
       "Resumed #{run.agent_id} as #{new_id} (role=#{run.role}). " <>
         "Running in the background; it will report back on completion."}
    else
      {:ok,
       "Cannot resume #{run.agent_id}: no original task or parent session recorded."}
    end
  end

  # Re-seed the prior task plus a tail of the transcript so the resumed agent has
  # continuity with the earlier run.
  defp resume_task(run) do
    run.task <>
      "\n\n[Resuming a previously stopped run of this task. Prior progress:]\n" <>
      prior_context(run.agent_id)
  end

  defp prior_context(agent_id) do
    case RunStore.transcript(agent_id) do
      {:ok, content} when is_binary(content) ->
        content |> String.slice(-2000, 2000) |> to_string()

      _ ->
        "(no prior transcript available)"
    end
  rescue
    _ -> "(no prior transcript available)"
  end

  defp handle_of(agent_id) do
    agent_id |> to_string() |> String.split(":") |> List.last()
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
