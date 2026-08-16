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
    - Liveness: #{liveness_line(run.agent_id)}
    - Doing: #{phase_line(run)}
    - Role: #{run.role}
    - Parent: #{run.parent_session_id}
    - Tools: #{run.tool_count}
    - Tokens: #{run.tokens_used}
    - Transcript: #{run.transcript_path}
    """
    |> String.trim()
  end

  # `run.status` is a STORED field, not a probe: a run whose process vanished
  # without writing a terminal status reports `:running` forever, so this tool
  # used to describe a dead agent as working and there was no way for anyone —
  # model or user — to tell. `RunStore.liveness/1` adjudicates against the
  # cross-process ownership lease, which is heartbeated by the owner and checked
  # against the OS pid AND its start time, so a recycled pid cannot pass for a
  # live one.
  defp liveness_line(agent_id) do
    case RunStore.liveness(agent_id) do
      {:alive, facts} ->
        "confirmed alive (a live process holds this run's lease)#{silence_note(facts)}"

      {:dead, _facts} ->
        "DEAD — the process that owned this run is gone and it never recorded a " <>
          "result. Its output is not coming. Re-dispatch it if the work still matters."

      {:finished, facts} ->
        "finished (#{facts.status})"

      {:unknown, facts} ->
        "unknown — no ownership lease could be read for this run" <> silence_note(facts)
    end
  rescue
    _ -> "unknown"
  end

  # Silence is reported from the BACKEND's own clock (`last_progress_at`), not
  # from when a UI last happened to receive a frame, and it is never presented
  # as evidence of death — a subagent inside a long build or a long generation
  # is silent and perfectly healthy.
  defp silence_note(%{silent_ms: ms}) when is_integer(ms) and ms >= 60_000 do
    ", last did something #{div(ms, 60_000)}m ago"
  end

  defp silence_note(%{silent_ms: ms}) when is_integer(ms) do
    ", last did something #{div(ms, 1000)}s ago"
  end

  defp silence_note(_), do: ""

  # What the agent is doing right now, for the whole stretch before it has any
  # tool activity to report — which on a real repo and a real model is minutes.
  defp phase_line(run) do
    detail = Map.get(run, :phase_detail)

    case Map.get(run, :phase) do
      nil -> "not reported"
      :queued -> "queued, not started yet" <> paren(detail)
      :starting -> "starting up" <> paren(detail)
      :awaiting_model -> "waiting on the model" <> paren(detail)
      :working -> "running tools" <> paren(detail)
      other -> to_string(other) <> paren(detail)
    end
  end

  defp paren(nil), do: ""
  defp paren(""), do: ""
  defp paren(d), do: " (#{d})"
end
