<!-- src/lib/components/agents/AgentDetail.svelte -->
<!-- Full-page agent detail with Overview | Configuration | Runs | Budget tabs. -->
<script lang="ts">
  import type { Agent, AgentBudget, CostEvent } from '$lib/api/types';
  import AgentOverview from './AgentOverview.svelte';
  import AgentConfig from './AgentConfig.svelte';
  import AgentRunHistory from './AgentRunHistory.svelte';
  import AgentBudgetTab from './AgentBudgetTab.svelte';

  interface Props {
    agent: Agent;
    budget: AgentBudget | null;
    costEvents: CostEvent[];
    onPause?: () => void;
    onResume?: () => void;
  }

  let { agent, budget, costEvents, onPause, onResume }: Props = $props();

  type Tab = 'overview' | 'config' | 'runs' | 'budget';
  let activeTab = $state<Tab>('overview');

  const tabs: { id: Tab; label: string }[] = [
    { id: 'overview', label: 'Overview' },
    { id: 'config', label: 'Configuration' },
    { id: 'runs', label: 'Runs' },
    { id: 'budget', label: 'Budget' },
  ];

  const isActive = $derived(agent.status === 'running' || agent.status === 'queued');

  function statusLabel(status: Agent['status']): string {
    switch (status) {
      case 'running': return 'Running';
      case 'queued':  return 'Queued';
      case 'done':    return 'Done';
      case 'error':   return 'Failed';
      case 'idle':    return 'Idle';
    }
  }
</script>

<div class="adet-shell">
  <!-- ── Detail header ── -->
  <header class="adet-header">
    <div class="adet-identity">
      <div
        class="adet-status-dot"
        class:adet-status-dot--running={agent.status === 'running'}
        class:adet-status-dot--queued={agent.status === 'queued'}
        class:adet-status-dot--done={agent.status === 'done'}
        class:adet-status-dot--error={agent.status === 'error'}
        aria-hidden="true"
      ></div>
      <div class="adet-name-group">
        <h1 class="adet-name">{agent.name}</h1>
        <div class="adet-badges">
          <span
            class="adet-badge adet-badge--status"
            class:adet-badge--running={agent.status === 'running'}
            class:adet-badge--queued={agent.status === 'queued'}
            class:adet-badge--done={agent.status === 'done'}
            class:adet-badge--error={agent.status === 'error'}
          >
            {statusLabel(agent.status)}
          </span>
          <span class="adet-badge adet-badge--id">
            {agent.id.slice(0, 8)}
          </span>
        </div>
      </div>
    </div>

    <div class="adet-actions">
      {#if isActive}
        <button
          class="adet-action-btn adet-action-btn--pause"
          onclick={() => onPause?.()}
          aria-label="Pause agent {agent.name}"
        >
          <svg width="11" height="11" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
            <rect x="2" y="1.5" width="3" height="9" rx="1"/>
            <rect x="7" y="1.5" width="3" height="9" rx="1"/>
          </svg>
          Pause
        </button>
      {:else if agent.status === 'idle'}
        <button
          class="adet-action-btn adet-action-btn--resume"
          onclick={() => onResume?.()}
          aria-label="Resume agent {agent.name}"
        >
          <svg width="11" height="11" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
            <path d="M3 2.5L10 6L3 9.5V2.5Z"/>
          </svg>
          Resume
        </button>
      {/if}
    </div>
  </header>

  <!-- ── Tab bar ── -->
  <div class="adet-tabs" role="tablist" aria-label="Agent detail sections">
    {#each tabs as tab (tab.id)}
      <button
        class="adet-tab"
        class:adet-tab--active={activeTab === tab.id}
        role="tab"
        aria-selected={activeTab === tab.id}
        aria-controls="adet-panel-{tab.id}"
        onclick={() => (activeTab = tab.id)}
      >
        {tab.label}
      </button>
    {/each}
  </div>

  <!-- ── Tab content ── -->
  <div class="adet-content" role="tabpanel" id="adet-panel-{activeTab}" aria-label="{activeTab} tab">
    {#if activeTab === 'overview'}
      <AgentOverview {agent} />
    {:else if activeTab === 'config'}
      <AgentConfig {agent} />
    {:else if activeTab === 'runs'}
      <AgentRunHistory agentName={agent.name} {costEvents} />
    {:else if activeTab === 'budget'}
      <AgentBudgetTab {agent} {budget} {costEvents} />
    {/if}
  </div>
</div>

<style>
  .adet-shell {
    display: flex;
    flex-direction: column;
    flex: 1;
    overflow: hidden;
  }

  /* ── Header ── */

  .adet-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 16px 24px 14px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
    gap: 16px;
  }

  .adet-identity {
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
  }

  .adet-status-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.18);
    flex-shrink: 0;
  }

  .adet-status-dot--running {
    background: var(--accent-success);
    box-shadow: 0 0 8px rgba(34, 197, 94, 0.5);
    animation: adet-pulse 2s ease-in-out infinite;
  }

  .adet-status-dot--queued {
    background: var(--accent-primary);
    box-shadow: 0 0 8px rgba(59, 130, 246, 0.4);
    animation: adet-pulse-blue 2s ease-in-out infinite;
  }

  .adet-status-dot--done   { background: rgba(255, 255, 255, 0.25); }
  .adet-status-dot--error  { background: var(--accent-error); box-shadow: 0 0 8px rgba(239, 68, 68, 0.4); }

  @keyframes adet-pulse {
    0%, 100% { box-shadow: 0 0 4px rgba(34, 197, 94, 0.4); }
    50%       { box-shadow: 0 0 12px rgba(34, 197, 94, 0.7); }
  }

  @keyframes adet-pulse-blue {
    0%, 100% { box-shadow: 0 0 4px rgba(59, 130, 246, 0.3); }
    50%       { box-shadow: 0 0 12px rgba(59, 130, 246, 0.6); }
  }

  .adet-name-group {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 0;
  }

  .adet-name {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .adet-badges {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .adet-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 7px;
    border-radius: var(--radius-full);
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.06);
  }

  .adet-badge--running { background: rgba(34, 197, 94, 0.12); color: rgba(34, 197, 94, 0.9); border-color: rgba(34, 197, 94, 0.2); }
  .adet-badge--queued  { background: rgba(59, 130, 246, 0.12); color: rgba(59, 130, 246, 0.9); border-color: rgba(59, 130, 246, 0.2); }
  .adet-badge--done    { background: rgba(255, 255, 255, 0.06); color: rgba(255, 255, 255, 0.4); border-color: rgba(255, 255, 255, 0.06); }
  .adet-badge--error   { background: rgba(239, 68, 68, 0.12); color: rgba(239, 68, 68, 0.9); border-color: rgba(239, 68, 68, 0.2); }
  .adet-badge--id      { font-family: var(--font-mono); font-size: 0.6rem; letter-spacing: 0.04em; text-transform: none; }

  /* ── Actions ── */

  .adet-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }

  .adet-action-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 14px;
    border-radius: var(--radius-md);
    border: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s, color 0.15s;
  }

  .adet-action-btn:hover {
    background: rgba(255, 255, 255, 0.09);
    border-color: rgba(255, 255, 255, 0.18);
    color: var(--text-primary);
  }

  .adet-action-btn--resume {
    background: rgba(34, 197, 94, 0.08);
    border-color: rgba(34, 197, 94, 0.2);
    color: rgba(34, 197, 94, 0.85);
  }

  .adet-action-btn--resume:hover {
    background: rgba(34, 197, 94, 0.14);
    border-color: rgba(34, 197, 94, 0.35);
  }

  /* ── Tab bar ── */

  .adet-tabs {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 8px 24px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    flex-shrink: 0;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .adet-tabs::-webkit-scrollbar { display: none; }


  .adet-tab {
    padding: 5px 14px;
    border-radius: var(--radius-md);
    border: none;
    background: none;
    color: var(--text-tertiary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    white-space: nowrap;
    transition: background 0.15s, color 0.15s;
  }

  .adet-tab:hover:not(.adet-tab--active) {
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
  }

  .adet-tab--active {
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-primary);
  }

  /* ── Content ── */

  .adet-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }
</style>
