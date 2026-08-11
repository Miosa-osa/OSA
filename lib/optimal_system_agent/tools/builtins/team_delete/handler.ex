defmodule OptimalSystemAgent.Tools.Builtins.TeamDelete.Handler do
  @moduledoc """
  Validation, permission, and execution for `team_delete`.

  Stage 1 — validate/2:
    Confirms `team_id` is a non-empty binary string.

  Stage 2 — check_permissions/2:
    Denied in `:read_only` or `:workspace` permission tiers.
    Requires at minimum `:full` or `:subagent` tier.

  Stage 3 — execute/2:
    Delegates to `OptimalSystemAgent.Teams.Manager.dissolve_team/1`.

    `dissolve_team/1` is the cleanest delete API available — it performs
    depth-first recursive child dissolution, stops all agents, tears down
    NervousSystem processes, destroys ETS tables, stops the Manager and
    CostTracker via `Teams.Supervisor.stop_team/1`, and broadcasts the
    `:team_dissolved` event. It is idempotent: a missing team_id returns :ok.
  """

  alias OptimalSystemAgent.Teams.Manager
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"team_id" => team_id} = input, _ctx) when is_binary(team_id) do
    if String.trim(team_id) == "" do
      {:error, "team_id must not be empty", -32_602}
    else
      {:ok, input}
    end
  end

  def validate(%{"team_id" => _}, _ctx) do
    {:error, "team_id must be a string", -32_602}
  end

  def validate(_input, _ctx) do
    {:error, "Missing required parameter: team_id", -32_602}
  end

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(_input, %UseContext{permission_tier: tier})
      when tier in [:read_only, :workspace] do
    {:deny,
     "team_delete is a destructive operation — " <>
       "requires permission tier :full or :subagent (current: #{tier})"}
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"team_id" => team_id}, _ctx) do
    # dissolve_team/1 is idempotent — returns :ok even when the team is
    # already gone. We check existence first so we can return a meaningful
    # message, but we don't treat a missing team as an error.
    existed = Manager.team_alive?(team_id)

    :ok = Manager.dissolve_team(team_id)

    if existed do
      {:ok, "Team #{team_id} dissolved. All agents stopped and resources reclaimed."}
    else
      {:ok, "Team #{team_id} not found — nothing to dissolve."}
    end
  rescue
    e ->
      {:error,
       "Failed to dissolve team #{Map.get(%{}, "team_id", "unknown")}: #{Exception.message(e)}"}
  end
end
