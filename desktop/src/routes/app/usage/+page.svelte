<!-- src/routes/app/usage/+page.svelte -->
<script lang="ts">
  import { onMount } from 'svelte';
  import { usageStore, type AnalyticsPeriod } from '$lib/stores/usage.svelte';
  import UsageDashboard  from '$lib/components/usage/UsageDashboard.svelte';
  import BudgetOverview  from '$lib/components/usage/BudgetOverview.svelte';
  import BudgetAlerts    from '$lib/components/usage/BudgetAlerts.svelte';
  import CostBreakdown   from '$lib/components/usage/CostBreakdown.svelte';
  import BudgetControls  from '$lib/components/usage/BudgetControls.svelte';

  // ── Constants ────────────────────────────────────────────────────────────────

  const PERIODS: { label: string; value: AnalyticsPeriod }[] = [
    { label: '7d',  value: '7d'  },
    { label: '30d', value: '30d' },
    { label: 'All', value: 'all' },
  ];

  // ── Derived ──────────────────────────────────────────────────────────────────

  let stats        = $derived(usageStore.stats);
  let loading      = $derived(usageStore.loading);
  let error        = $derived(usageStore.error);
  let period       = $derived(usageStore.period);
  let dailyData    = $derived(usageStore.filteredDailyUsage());
  let byModel      = $derived(stats?.modelUsage ?? []);
  let summary      = $derived(usageStore.summary);
  let agentBudgets = $derived(usageStore.agentBudgets);
  let costByModel  = $derived(usageStore.costByModel);
  let costByAgent  = $derived(usageStore.costByAgent);
  let budgetLoading = $derived(usageStore.budgetLoading);
  let pausedAgents = $derived(usageStore.pausedAgents());

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  onMount(() => {
    usageStore.fetchUsage();
    usageStore.fetchBudgets();
  });
</script>

<svelte:head>
  <title>Usage — OSA</title>
</svelte:head>

<div class="up-container" aria-label="Usage and analytics">

  <!-- Header -->
  <header class="up-header">
    <div class="up-header-left">
      <h1 class="up-title">Usage & Analytics</h1>
      <p class="up-subtitle">Message and token activity across sessions</p>
    </div>

    <div class="up-period-selector" role="group" aria-label="Time period">
      {#each PERIODS as p (p.value)}
        <button
          class="up-period-btn"
          class:up-period-btn--active={period === p.value}
          onclick={() => usageStore.setPeriod(p.value)}
          aria-pressed={period === p.value}
          aria-label="View {p.label} period"
        >
          {p.label}
        </button>
      {/each}
    </div>
  </header>

  <!-- Content -->
  <main class="up-content">

    <!-- Error state -->
    {#if error && !stats}
      <div class="up-error glass-panel" role="alert">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor"
          stroke-width="1.75" aria-hidden="true">
          <circle cx="12" cy="12" r="10"/>
          <line x1="12" y1="8" x2="12" y2="12"/>
          <line x1="12" y1="16" x2="12.01" y2="16"/>
        </svg>
        <div class="up-error-body">
          <p class="up-error-title">Failed to load usage data</p>
          <p class="up-error-msg">{error}</p>
        </div>
        <button
          class="up-retry-btn"
          onclick={() => usageStore.fetchUsage()}
          aria-label="Retry loading usage data"
        >
          Retry
        </button>
      </div>
    {/if}

    <BudgetAlerts
      dailySpent={summary?.daily_spent_cents ?? 0}
      dailyLimit={summary?.daily_limit_cents ?? 25000}
      monthlySpent={summary?.monthly_spent_cents ?? 0}
      monthlyLimit={summary?.monthly_limit_cents ?? 250000}
      {pausedAgents}
    />

    <BudgetOverview
      dailySpent={summary?.daily_spent_cents ?? 0}
      dailyLimit={summary?.daily_limit_cents ?? 25000}
      monthlySpent={summary?.monthly_spent_cents ?? 0}
      monthlyLimit={summary?.monthly_limit_cents ?? 250000}
      agents={agentBudgets}
      loading={budgetLoading}
    />

    <UsageDashboard
      {loading}
      {period}
      totalMessages={stats?.totalMessages ?? 0}
      totalSessions={stats?.totalSessions ?? 0}
      totalTokensFormatted={usageStore.totalTokensFormatted()}
      avgResponseTime={stats?.avgResponseTime ?? 0}
      {byModel}
      {dailyData}
    />

    <CostBreakdown
      byModel={costByModel.map((m) => ({ model: m.model, cost_cents: m.cost_cents, count: m.count }))}
      byAgent={costByAgent.map((a) => ({ agent_name: a.agent_name, cost_cents: a.cost_cents, count: a.count }))}
      loading={budgetLoading}
    />

    <BudgetControls
      agents={agentBudgets}
      onUpdate={(name, daily, monthly) => usageStore.updateBudget(name, daily, monthly)}
      onReset={(name) => usageStore.resetBudget(name)}
      loading={budgetLoading}
    />

  </main>
</div>

<style>
  .up-container {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  .up-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 20px 24px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
  }

  .up-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px 24px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .up-header-left {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .up-title {
    font-size: 20px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
  }

  .up-subtitle {
    font-size: 13px;
    color: var(--text-tertiary);
  }

  /* Period selector */
  .up-period-selector {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 3px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md);
    flex-shrink: 0;
  }

  .up-period-btn {
    padding: 5px 14px;
    font-size: 12px;
    font-weight: 500;
    color: var(--text-tertiary);
    background: transparent;
    border: 1px solid transparent;
    border-radius: calc(var(--radius-md) - 3px);
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease;
    white-space: nowrap;
  }

  .up-period-btn:hover:not(.up-period-btn--active) {
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.05);
  }

  .up-period-btn--active {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.15);
    color: var(--text-primary);
    font-weight: 600;
  }

  .up-period-btn:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }

  /* Error state */
  .up-error {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 14px 16px;
    color: var(--text-secondary);
  }

  .up-error svg {
    color: var(--accent-error);
    flex-shrink: 0;
  }

  .up-error-body {
    flex: 1;
    min-width: 0;
  }

  .up-error-title {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
  }

  .up-error-msg {
    font-size: 12px;
    color: var(--text-tertiary);
    margin-top: 2px;
  }

  .up-retry-btn {
    padding: 5px 14px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    font-size: 12px;
    font-weight: 500;
    color: var(--text-primary);
    cursor: pointer;
    transition: background 0.15s ease;
    flex-shrink: 0;
  }

  .up-retry-btn:hover {
    background: rgba(255, 255, 255, 0.12);
  }

  .up-retry-btn:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }
</style>
