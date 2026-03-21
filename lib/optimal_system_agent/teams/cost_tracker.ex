defmodule OptimalSystemAgent.Teams.CostTracker do
  @moduledoc """
  Per-team budget tracking GenServer.

  Responsibilities:

  * Records token spend per agent and aggregates to team totals
  * Token-bucket rate limiting — agents that exceed their per-minute token
    quota are asked to slow down
  * Per-agent spend limits derived from the team's total budget
  * Model escalation: if a cheap model fails the same task twice, automatically
    recommend the next model tier (haiku → sonnet → opus)
  * Alerts when team spend approaches the configured budget ceiling

  ## Configuration

  The GenServer accepts these opts at start:

    - `:team_id` (required) — the team this tracker belongs to
    - `:budget_usd` — total USD budget for the team (default: 1.0)
    - `:alert_threshold` — fraction of budget that triggers an alert (default: 0.8)
    - `:agent_share` — max fraction of total budget any single agent may spend (default: 0.3)
    - `:rate_limit_tokens_per_minute` — token bucket capacity per agent (default: 50_000)

  ## Token bucket

  Each agent gets an independent token bucket that refills at
  `:rate_limit_tokens_per_minute` tokens per minute. Calls to
  `check_rate_limit/2` consume from the bucket; a `:slow_down` response
  signals the caller to back off before the next LLM call.

  ## Model escalation

  `record_task_failure/3` tracks consecutive failures per task+agent pair.
  When an agent fails the same task twice, `escalate_model/1` returns the
  next tier:

      haiku/utility → sonnet/specialist → opus/elite
  """

  use GenServer
  require Logger

  @alert_threshold_default 0.80
  @agent_share_default 0.30
  @rate_limit_default 50_000

  # Model escalation ladder: tier atom -> next tier atom
  @escalation_ladder %{
    :utility    => :specialist,
    :specialist => :elite,
    :elite      => :elite
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    GenServer.start_link(__MODULE__, opts, name: via(team_id))
  end

  @doc "Record a spend event for an agent. Returns `:ok` or `{:error, :budget_exceeded}`."
  @spec record_spend(String.t(), String.t(), non_neg_integer(), float()) ::
          :ok | {:error, :budget_exceeded}
  def record_spend(team_id, agent_id, tokens, cost_usd) do
    GenServer.call(via(team_id), {:record_spend, agent_id, tokens, cost_usd})
  end

  @doc "Get aggregate spend for the whole team."
  @spec get_team_spend(String.t()) :: %{tokens: non_neg_integer(), cost_usd: float()}
  def get_team_spend(team_id) do
    GenServer.call(via(team_id), :get_team_spend)
  end

  @doc "Get spend totals for a single agent."
  @spec get_agent_spend(String.t(), String.t()) ::
          %{tokens: non_neg_integer(), cost_usd: float()} | nil
  def get_agent_spend(team_id, agent_id) do
    GenServer.call(via(team_id), {:get_agent_spend, agent_id})
  end

  @doc """
  Check if the agent is within its rate limit.

  Returns `:ok` if the agent can proceed, or `{:slow_down, retry_after_ms}`
  when the token bucket is empty.
  """
  @spec check_rate_limit(String.t(), String.t()) ::
          :ok | {:slow_down, non_neg_integer()}
  def check_rate_limit(team_id, agent_id) do
    GenServer.call(via(team_id), {:check_rate_limit, agent_id})
  end

  @doc """
  Record a task failure for a specific agent+task pair.

  When the same task fails twice consecutively, returns
  `{:escalate, new_tier}` with the recommended higher model tier.
  Returns `:ok` on first failure or when already at the top tier.
  """
  @spec record_task_failure(String.t(), String.t(), String.t()) ::
          :ok | {:escalate, atom()}
  def record_task_failure(team_id, agent_id, task_id) do
    GenServer.call(via(team_id), {:record_task_failure, agent_id, task_id})
  end

  @doc "Clear the failure counter for a task (call on success)."
  @spec clear_task_failures(String.t(), String.t(), String.t()) :: :ok
  def clear_task_failures(team_id, agent_id, task_id) do
    GenServer.cast(via(team_id), {:clear_task_failures, agent_id, task_id})
  end

  @doc "Get the full budget summary: team totals, per-agent breakdown, rate limits."
  @spec budget_summary(String.t()) :: map()
  def budget_summary(team_id) do
    GenServer.call(via(team_id), :budget_summary)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    team_id       = Keyword.fetch!(opts, :team_id)
    budget_usd    = Keyword.get(opts, :budget_usd, 1.0) * 1.0
    alert_at      = Keyword.get(opts, :alert_threshold, @alert_threshold_default)
    agent_share   = Keyword.get(opts, :agent_share, @agent_share_default)
    rate_limit    = Keyword.get(opts, :rate_limit_tokens_per_minute, @rate_limit_default)

    state = %{
      team_id:       team_id,
      budget_usd:    budget_usd,
      alert_threshold: alert_at,
      agent_share:   agent_share,
      rate_limit:    rate_limit,
      # team totals
      team_tokens:   0,
      team_cost_usd: 0.0,
      alert_fired:   false,
      # per-agent: %{agent_id => %{tokens, cost_usd}}
      agent_spend:   %{},
      # token buckets: %{agent_id => {tokens_remaining, refill_at_monotonic}}
      buckets:       %{},
      # failure counts: %{{agent_id, task_id} => consecutive_count}
      failures:      %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:record_spend, agent_id, tokens, cost_usd}, _from, state) do
    agent_max = state.budget_usd * state.agent_share
    current   = Map.get(state.agent_spend, agent_id, %{tokens: 0, cost_usd: 0.0})

    if current.cost_usd + cost_usd > agent_max do
      Logger.warning("[CostTracker:#{state.team_id}] Agent #{agent_id} exceeded spend limit (#{agent_max} USD)")
      {:reply, {:error, :budget_exceeded}, state}
    else
      updated_agent = %{
        tokens:   current.tokens + tokens,
        cost_usd: current.cost_usd + cost_usd
      }
      new_team_tokens   = state.team_tokens + tokens
      new_team_cost_usd = state.team_cost_usd + cost_usd
      new_agent_spend   = Map.put(state.agent_spend, agent_id, updated_agent)

      state = %{state |
        team_tokens:   new_team_tokens,
        team_cost_usd: new_team_cost_usd,
        agent_spend:   new_agent_spend
      }

      state = maybe_fire_budget_alert(state)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:get_team_spend, _from, state) do
    result = %{tokens: state.team_tokens, cost_usd: state.team_cost_usd}
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_agent_spend, agent_id}, _from, state) do
    result = Map.get(state.agent_spend, agent_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:check_rate_limit, agent_id}, _from, state) do
    now     = System.monotonic_time(:millisecond)
    bucket  = Map.get(state.buckets, agent_id, fresh_bucket(state.rate_limit, now))
    bucket  = maybe_refill(bucket, state.rate_limit, now)

    if bucket.tokens > 0 do
      updated  = %{bucket | tokens: bucket.tokens - 1}
      new_bkts = Map.put(state.buckets, agent_id, updated)
      {:reply, :ok, %{state | buckets: new_bkts}}
    else
      # Bucket empty: estimate wait time until refill (ms per token at 1/min rate)
      ms_per_token = div(60_000, max(state.rate_limit, 1))
      {:reply, {:slow_down, ms_per_token}, state}
    end
  end

  @impl true
  def handle_call({:record_task_failure, agent_id, task_id}, _from, state) do
    key   = {agent_id, task_id}
    count = Map.get(state.failures, key, 0) + 1
    new_failures = Map.put(state.failures, key, count)
    state = %{state | failures: new_failures}

    reply =
      if count >= 2 do
        # Determine current tier from agent_spend metadata (best-effort)
        # Default assume :specialist for escalation calculation
        current_tier = Map.get(state.agent_spend, agent_id, %{}) |> Map.get(:tier, :specialist)
        next_tier    = Map.get(@escalation_ladder, current_tier, :elite)
        Logger.info("[CostTracker:#{state.team_id}] Escalating agent #{agent_id} to #{next_tier} after #{count} failures on task #{task_id}")
        {:escalate, next_tier}
      else
        :ok
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:budget_summary, _from, state) do
    summary = %{
      team_id:      state.team_id,
      budget_usd:   state.budget_usd,
      spent_usd:    state.team_cost_usd,
      remaining_usd: max(state.budget_usd - state.team_cost_usd, 0.0),
      pct_used:     if(state.budget_usd > 0, do: state.team_cost_usd / state.budget_usd * 100, else: 0.0),
      alert_fired:  state.alert_fired,
      agents:       state.agent_spend
    }

    {:reply, summary, state}
  end

  @impl true
  def handle_cast({:clear_task_failures, agent_id, task_id}, state) do
    new_failures = Map.delete(state.failures, {agent_id, task_id})
    {:noreply, %{state | failures: new_failures}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp via(team_id) do
    {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, team_id}}}
  end

  defp maybe_fire_budget_alert(%{alert_fired: true} = state), do: state
  defp maybe_fire_budget_alert(state) do
    pct = if state.budget_usd > 0, do: state.team_cost_usd / state.budget_usd, else: 0.0

    if pct >= state.alert_threshold do
      Logger.warning("[CostTracker:#{state.team_id}] Budget alert: #{Float.round(pct * 100, 1)}% of #{state.budget_usd} USD consumed")

      # Emit an algedonic alert through the event bus (best-effort)
      try do
        OptimalSystemAgent.Events.Bus.emit_algedonic(:high,
          "Team #{state.team_id} has consumed #{Float.round(pct * 100, 1)}% of its budget",
          source: "cost_tracker",
          metadata: %{team_id: state.team_id, pct_used: pct, spent_usd: state.team_cost_usd}
        )
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      %{state | alert_fired: true}
    else
      state
    end
  end

  defp fresh_bucket(rate_limit, now) do
    %{tokens: rate_limit, refill_at: now + 60_000}
  end

  # Refill the bucket if the 1-minute window has elapsed.
  defp maybe_refill(%{refill_at: refill_at} = bucket, rate_limit, now) do
    if now >= refill_at do
      %{bucket | tokens: rate_limit, refill_at: now + 60_000}
    else
      bucket
    end
  end
end
