<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { goto } from '$app/navigation';
  import { agents as agentsApi, budgets as budgetsApi, costs as costsApi } from '$lib/api/client';
  import type { Agent, AgentBudget, CostEvent } from '$lib/api/types';
  import AgentDetail from '$lib/components/agents/AgentDetail.svelte';

  interface Props {
    data: { agentId: string };
  }

  let { data }: Props = $props();

  // ── State ────────────────────────────────────────────────────────────────────

  let agent = $state<Agent | null>(null);
  let budget = $state<AgentBudget | null>(null);
  let costEvents = $state<CostEvent[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let pollTimer: ReturnType<typeof setInterval> | null = null;

  // ── Data fetching ────────────────────────────────────────────────────────────

  async function fetchAgent(): Promise<void> {
    try {
      // Try direct get first; fall back to list filter if 404
      try {
        agent = await agentsApi.get(data.agentId);
      } catch {
        const all = await agentsApi.list();
        const found = all.find((a) => a.id === data.agentId);
        if (!found) throw new Error('Agent not found');
        agent = found;
      }
      error = null;
    } catch (err) {
      error = err instanceof Error ? err.message : 'Failed to load agent';
    }
  }

  async function fetchBudget(): Promise<void> {
    if (!agent) return;
    try {
      const result = await budgetsApi.list();
      budget = result.budgets.find((b) => b.agent_name === agent!.name) ?? null;
    } catch {
      // Budget data is best-effort
    }
  }

  async function fetchCostEvents(): Promise<void> {
    if (!agent) return;
    try {
      const result = await costsApi.events(1, 50, agent.name);
      costEvents = result.events;
    } catch {
      // Cost data is best-effort
    }
  }

  async function loadAll(): Promise<void> {
    loading = true;
    await fetchAgent();
    await Promise.all([fetchBudget(), fetchCostEvents()]);
    loading = false;
  }

  // ── Actions ──────────────────────────────────────────────────────────────────

  async function handlePause(): Promise<void> {
    if (!agent) return;
    try {
      await agentsApi.pause(agent.id);
      agent = { ...agent, status: 'idle' };
    } catch { /* server poll will correct */ }
  }

  async function handleResume(): Promise<void> {
    if (!agent) return;
    try {
      await agentsApi.resume(agent.id);
      agent = { ...agent, status: 'running' };
    } catch { /* server poll will correct */ }
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  onMount(async () => {
    await loadAll();
    pollTimer = setInterval(() => {
      void fetchAgent();
    }, 5000);
  });

  onDestroy(() => {
    if (pollTimer !== null) clearInterval(pollTimer);
  });
</script>

<svelte:head>
  <title>{agent?.name ?? 'Agent'} — OSA</title>
</svelte:head>

<div class="ad-page">
  <!-- Back navigation -->
  <div class="ad-back-row">
    <button
      class="ad-back-btn"
      onclick={() => goto('/app/agents')}
      aria-label="Back to agents list"
    >
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <line x1="11" y1="7" x2="3" y2="7"/>
        <polyline points="6,4 3,7 6,10"/>
      </svg>
      Agents
    </button>
  </div>

  {#if loading}
    <div class="ad-loading" role="status" aria-label="Loading agent">
      <span class="ad-spinner" aria-hidden="true"></span>
      <span class="ad-loading-text">Loading agent...</span>
    </div>

  {:else if error}
    <div class="ad-error" role="alert">
      <p class="ad-error-title">Failed to load agent</p>
      <p class="ad-error-message">{error}</p>
      <button class="ad-retry-btn" onclick={() => loadAll()} aria-label="Retry loading agent">
        Retry
      </button>
    </div>

  {:else if agent}
    <AgentDetail
      {agent}
      {budget}
      {costEvents}
      onPause={handlePause}
      onResume={handleResume}
    />
  {/if}
</div>

<style>
  .ad-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  /* ── Back row ── */

  .ad-back-row {
    padding: 14px 24px 0;
    flex-shrink: 0;
  }

  .ad-back-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 10px 5px 8px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-md);
    color: var(--text-tertiary);
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, color 0.15s, border-color 0.15s;
  }

  .ad-back-btn:hover {
    background: rgba(255, 255, 255, 0.08);
    border-color: rgba(255, 255, 255, 0.12);
    color: var(--text-secondary);
  }

  /* ── Loading ── */

  .ad-loading {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    flex: 1;
    gap: 12px;
  }

  .ad-spinner {
    width: 24px;
    height: 24px;
    border: 2px solid rgba(255, 255, 255, 0.08);
    border-top-color: rgba(255, 255, 255, 0.4);
    border-radius: 50%;
    animation: ad-spin 0.8s linear infinite;
  }

  @keyframes ad-spin {
    to { transform: rotate(360deg); }
  }

  .ad-loading-text {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
  }

  /* ── Error ── */

  .ad-error {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    flex: 1;
    gap: 8px;
    padding: 48px 32px;
    text-align: center;
  }

  .ad-error-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .ad-error-message {
    font-size: 0.8125rem;
    color: rgba(239, 68, 68, 0.7);
    max-width: 320px;
  }

  .ad-retry-btn {
    margin-top: 8px;
    padding: 7px 20px;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: var(--radius-md);
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s;
  }

  .ad-retry-btn:hover {
    background: rgba(255, 255, 255, 0.1);
  }
</style>
