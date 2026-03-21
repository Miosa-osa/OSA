<!-- src/lib/components/agents/AgentBudgetTab.svelte -->
<!-- Budget tab: daily/monthly spend, limits, cost-event breakdown by model. -->
<script lang="ts">
  import type { Agent, AgentBudget, CostEvent } from '$lib/api/types';

  interface Props {
    agent: Agent;
    budget: AgentBudget | null;
    costEvents: CostEvent[];
  }

  let { agent, budget, costEvents }: Props = $props();

  function formatCostCents(cents: number): string {
    if (cents === 0) return '$0.00';
    return `$${(cents / 100).toFixed(4)}`;
  }

  function formatTokens(n: number): string {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
    if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
    return String(n);
  }

  function pct(spent: number, limit: number): number {
    if (limit <= 0) return 0;
    return Math.min(100, Math.round((spent / limit) * 100));
  }

  // Aggregate tokens across all cost events
  const totalInputTokens = $derived(costEvents.reduce((s, e) => s + e.input_tokens, 0));
  const totalOutputTokens = $derived(costEvents.reduce((s, e) => s + e.output_tokens, 0));
  const totalCacheRead = $derived(costEvents.reduce((s, e) => s + e.cache_read_tokens, 0));

  // By-model breakdown
  type ModelAgg = { model: string; provider: string; tokens: number; cost_cents: number; count: number };
  const byModel = $derived.by((): ModelAgg[] => {
    const map = new Map<string, ModelAgg>();
    for (const e of costEvents) {
      const key = `${e.provider}::${e.model}`;
      const existing = map.get(key);
      if (existing) {
        existing.tokens += e.input_tokens + e.output_tokens;
        existing.cost_cents += e.cost_cents;
        existing.count += 1;
      } else {
        map.set(key, {
          model: e.model,
          provider: e.provider,
          tokens: e.input_tokens + e.output_tokens,
          cost_cents: e.cost_cents,
          count: 1,
        });
      }
    }
    return [...map.values()].sort((a, b) => b.cost_cents - a.cost_cents);
  });

  const dailyPct = $derived(
    budget ? pct(budget.spent_daily_cents, budget.budget_daily_cents) : 0
  );

  const monthlyPct = $derived(
    budget ? pct(budget.spent_monthly_cents, budget.budget_monthly_cents) : 0
  );

  function budgetBarColor(pct: number): string {
    if (pct >= 90) return 'rgba(239, 68, 68, 0.8)';
    if (pct >= 70) return 'rgba(251, 191, 36, 0.8)';
    return 'rgba(34, 197, 94, 0.7)';
  }
</script>

<div class="abgt-root">

  <!-- ── Budget limits ── -->
  {#if budget}
    <section class="abgt-card" aria-label="Budget limits">
      <div class="abgt-card-header">
        <h2 class="abgt-section-title">Budget Status</h2>
        <span
          class="abgt-status-badge"
          class:abgt-status-badge--active={budget.status === 'active'}
          class:abgt-status-badge--paused={budget.status !== 'active'}
        >
          {budget.status === 'active' ? 'Active' : budget.status === 'paused_budget' ? 'Paused (budget)' : 'Paused (manual)'}
        </span>
      </div>

      <!-- Daily -->
      <div class="abgt-budget-row">
        <div class="abgt-budget-meta">
          <span class="abgt-budget-label">Daily</span>
          <span class="abgt-budget-numbers">
            {formatCostCents(budget.spent_daily_cents)} / {formatCostCents(budget.budget_daily_cents)}
          </span>
        </div>
        <div class="abgt-progress-track" role="progressbar" aria-valuenow={dailyPct} aria-valuemin={0} aria-valuemax={100} aria-label="Daily budget usage {dailyPct}%">
          <div
            class="abgt-progress-fill"
            style="width: {dailyPct}%; background: {budgetBarColor(dailyPct)}"
          ></div>
        </div>
        <span class="abgt-pct-label">{dailyPct}%</span>
      </div>

      <!-- Monthly -->
      <div class="abgt-budget-row">
        <div class="abgt-budget-meta">
          <span class="abgt-budget-label">Monthly</span>
          <span class="abgt-budget-numbers">
            {formatCostCents(budget.spent_monthly_cents)} / {formatCostCents(budget.budget_monthly_cents)}
          </span>
        </div>
        <div class="abgt-progress-track" role="progressbar" aria-valuenow={monthlyPct} aria-valuemin={0} aria-valuemax={100} aria-label="Monthly budget usage {monthlyPct}%">
          <div
            class="abgt-progress-fill"
            style="width: {monthlyPct}%; background: {budgetBarColor(monthlyPct)}"
          ></div>
        </div>
        <span class="abgt-pct-label">{monthlyPct}%</span>
      </div>
    </section>

  {:else}
    <div class="abgt-no-budget" role="status">
      <p class="abgt-no-budget-title">No budget configured</p>
      <p class="abgt-no-budget-sub">Set daily and monthly limits in the Budget settings page.</p>
    </div>
  {/if}

  <!-- ── Token summary ── -->
  <section class="abgt-card" aria-label="Token usage summary">
    <h2 class="abgt-section-title">Token Usage</h2>
    <div class="abgt-token-grid">
      <div class="abgt-token-cell">
        <span class="abgt-token-label">Input</span>
        <span class="abgt-token-value">{formatTokens(totalInputTokens)}</span>
      </div>
      <div class="abgt-token-cell">
        <span class="abgt-token-label">Output</span>
        <span class="abgt-token-value">{formatTokens(totalOutputTokens)}</span>
      </div>
      <div class="abgt-token-cell">
        <span class="abgt-token-label">Cache Read</span>
        <span class="abgt-token-value">{formatTokens(totalCacheRead)}</span>
      </div>
      <div class="abgt-token-cell">
        <span class="abgt-token-label">Total Events</span>
        <span class="abgt-token-value">{costEvents.length}</span>
      </div>
    </div>
  </section>

  <!-- ── By model ── -->
  {#if byModel.length > 0}
    <section class="abgt-card" aria-label="Cost breakdown by model">
      <h2 class="abgt-section-title">Cost by Model</h2>
      <div class="abgt-model-list" role="list">
        {#each byModel as row (row.model)}
          <div class="abgt-model-row" role="listitem">
            <div class="abgt-model-info">
              <span class="abgt-model-name">{row.model}</span>
              <span class="abgt-model-provider">{row.provider}</span>
            </div>
            <div class="abgt-model-stats">
              <span class="abgt-model-stat">
                <span class="abgt-model-stat-label">Calls</span>
                <span class="abgt-model-stat-value">{row.count}</span>
              </span>
              <span class="abgt-model-stat">
                <span class="abgt-model-stat-label">Tokens</span>
                <span class="abgt-model-stat-value">{formatTokens(row.tokens)}</span>
              </span>
              <span class="abgt-model-stat">
                <span class="abgt-model-stat-label">Cost</span>
                <span class="abgt-model-stat-value abgt-cost-value">{formatCostCents(row.cost_cents)}</span>
              </span>
            </div>
          </div>
        {/each}
      </div>
    </section>
  {:else}
    <div class="abgt-no-events" role="status">
      <p class="abgt-no-budget-title">No cost events</p>
      <p class="abgt-no-budget-sub">Cost data for <strong>{agent.name}</strong> will appear here after execution.</p>
    </div>
  {/if}

</div>

<style>
  .abgt-root {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .abgt-card {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
    padding: 16px 18px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .abgt-card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .abgt-section-title {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--text-muted);
    margin: 0;
  }

  .abgt-status-badge {
    padding: 2px 8px;
    border-radius: var(--radius-full);
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.07);
  }

  .abgt-status-badge--active {
    background: rgba(34, 197, 94, 0.1);
    color: rgba(34, 197, 94, 0.85);
    border-color: rgba(34, 197, 94, 0.2);
  }

  .abgt-status-badge--paused {
    background: rgba(251, 191, 36, 0.1);
    color: rgba(251, 191, 36, 0.85);
    border-color: rgba(251, 191, 36, 0.2);
  }

  /* ── Budget rows ── */

  .abgt-budget-row {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .abgt-budget-meta {
    display: flex;
    flex-direction: column;
    gap: 2px;
    width: 72px;
    flex-shrink: 0;
  }

  .abgt-budget-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .abgt-budget-numbers {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }

  .abgt-progress-track {
    flex: 1;
    height: 6px;
    background: rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    overflow: hidden;
  }

  .abgt-progress-fill {
    height: 100%;
    border-radius: var(--radius-full);
    transition: width 0.4s ease;
  }

  .abgt-pct-label {
    font-size: 0.6875rem;
    font-weight: 600;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
    width: 32px;
    text-align: right;
    flex-shrink: 0;
  }

  /* ── Token grid ── */

  .abgt-token-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
    gap: 1px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-md);
    overflow: hidden;
  }

  .abgt-token-cell {
    display: flex;
    flex-direction: column;
    gap: 3px;
    padding: 10px 12px;
    background: var(--bg-secondary);
  }

  .abgt-token-label {
    font-size: 0.5625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .abgt-token-value {
    font-size: 1rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  /* ── Model list ── */

  .abgt-model-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .abgt-model-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 10px 12px;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-md);
  }

  .abgt-model-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    flex: 1;
  }

  .abgt-model-name {
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .abgt-model-provider {
    font-size: 0.6875rem;
    color: var(--text-muted);
    text-transform: capitalize;
  }

  .abgt-model-stats {
    display: flex;
    align-items: center;
    gap: 16px;
    flex-shrink: 0;
  }

  .abgt-model-stat {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 2px;
  }

  .abgt-model-stat-label {
    font-size: 0.5625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .abgt-model-stat-value {
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .abgt-cost-value {
    color: rgba(34, 197, 94, 0.8) !important;
  }

  /* ── Empty states ── */

  .abgt-no-budget,
  .abgt-no-events {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 40px 32px;
    gap: 8px;
    text-align: center;
    background: rgba(255, 255, 255, 0.02);
    border: 1px dashed rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
  }

  .abgt-no-budget-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .abgt-no-budget-sub {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    max-width: 280px;
    line-height: 1.5;
  }

  .abgt-no-budget-sub strong {
    color: var(--text-secondary);
    font-weight: 500;
  }
</style>
