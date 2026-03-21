<!-- src/lib/components/agents/AgentGrid.svelte -->
<!-- Responsive grid of AgentCard components with filter tabs and empty state. -->
<script lang="ts">
  import type { Agent } from '$lib/api/types';
  import AgentCard from './AgentCard.svelte';

  type FilterMode = 'all' | 'active' | 'paused' | 'error';

  interface Props {
    agents: Agent[];
    onPause?: (agent: Agent) => void;
    onCancel?: (agent: Agent) => void;
    pendingIds?: Set<string>;
  }

  let {
    agents,
    onPause,
    onCancel,
    pendingIds = new Set(),
  }: Props = $props();

  // ── Filter state ─────────────────────────────────────────────────────────────

  let filterMode = $state<FilterMode>('all');

  // ── Expand state ─────────────────────────────────────────────────────────────

  let expandedIds = $state<Set<string>>(new Set());

  function toggleExpand(id: string) {
    const next = new Set(expandedIds);
    if (next.has(id)) {
      next.delete(id);
    } else {
      next.add(id);
    }
    expandedIds = next;
  }

  // ── Derived: filtered + sorted list ─────────────────────────────────────────

  const STATUS_ORDER: Record<Agent['status'], number> = {
    running: 0,
    queued:  1,
    idle:    2,
    done:    3,
    error:   4,
  };

  const filteredAgents = $derived.by((): Agent[] => {
    let list = [...agents];

    switch (filterMode) {
      case 'active':
        list = list.filter(a => a.status === 'running' || a.status === 'queued');
        break;
      case 'paused':
        list = list.filter(a => a.status === 'idle');
        break;
      case 'error':
        list = list.filter(a => a.status === 'error');
        break;
    }

    return list.sort((a, b) => STATUS_ORDER[a.status] - STATUS_ORDER[b.status]);
  });

  // ── Filter tab counts ────────────────────────────────────────────────────────

  const counts = $derived({
    all:    agents.length,
    active: agents.filter(a => a.status === 'running' || a.status === 'queued').length,
    paused: agents.filter(a => a.status === 'idle').length,
    error:  agents.filter(a => a.status === 'error').length,
  });
</script>

<div class="ag-root">
  <!-- ── Filter tabs ── -->
  <div class="ag-filters" role="tablist" aria-label="Filter agents by status">
    {#each (['all', 'active', 'paused', 'error'] as FilterMode[]) as mode}
      <button
        class="ag-filter-tab"
        class:ag-filter-tab--active={filterMode === mode}
        class:ag-filter-tab--error={mode === 'error' && counts.error > 0}
        onclick={() => filterMode = mode}
        role="tab"
        aria-selected={filterMode === mode}
        aria-label="{mode} agents ({counts[mode]})"
      >
        {mode === 'all' ? 'All' : mode.charAt(0).toUpperCase() + mode.slice(1)}
        <span class="ag-filter-count">{counts[mode]}</span>
      </button>
    {/each}
  </div>

  <!-- ── Grid or empty state ── -->
  {#if filteredAgents.length === 0}
    <div class="ag-empty" role="status">
      {#if filterMode === 'all'}
        <div class="ag-empty-icon" aria-hidden="true">
          <svg width="48" height="48" viewBox="0 0 48 48" fill="none">
            <rect x="8" y="8" width="14" height="14" rx="3" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.4"/>
            <rect x="26" y="8" width="14" height="14" rx="3" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.25"/>
            <rect x="8" y="26" width="14" height="14" rx="3" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.25"/>
            <rect x="26" y="26" width="14" height="14" rx="3" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.15"/>
            <circle cx="15" cy="15" r="2.5" fill="currentColor" opacity="0.5"/>
          </svg>
        </div>
        <p class="ag-empty-title">No agents running</p>
        <p class="ag-empty-sub">Agents will appear here when a task is dispatched from chat.</p>
      {:else}
        <p class="ag-empty-title">No {filterMode} agents</p>
        <p class="ag-empty-sub">Switch to "All" to see every agent.</p>
      {/if}
    </div>
  {:else}
    <div class="ag-grid" role="list" aria-label="Agent list">
      {#each filteredAgents as agent (agent.id)}
        <AgentCard
          {agent}
          isExpanded={expandedIds.has(agent.id)}
          isPending={pendingIds.has(agent.id)}
          onToggleExpand={toggleExpand}
          {onPause}
          {onCancel}
        />
      {/each}
    </div>
  {/if}
</div>

<style>
  /* ── Root ── */

  .ag-root {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  /* ── Filter tabs ── */

  .ag-filters {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .ag-filter-tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 12px;
    border-radius: var(--radius-full);
    border: 1px solid transparent;
    background: none;
    color: var(--text-tertiary);
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
    line-height: 1;
  }

  .ag-filter-tab:hover:not(.ag-filter-tab--active) {
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
    border-color: rgba(255, 255, 255, 0.07);
  }

  .ag-filter-tab--active {
    background: rgba(255, 255, 255, 0.09);
    color: var(--text-primary);
    border-color: rgba(255, 255, 255, 0.1);
  }

  .ag-filter-tab--error .ag-filter-count {
    background: rgba(239, 68, 68, 0.15);
    color: rgba(239, 68, 68, 0.85);
  }

  .ag-filter-count {
    font-size: 0.625rem;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    background: rgba(255, 255, 255, 0.07);
    color: var(--text-muted);
    border-radius: var(--radius-full);
    padding: 1px 5px;
    min-width: 16px;
    text-align: center;
    line-height: 1.5;
  }

  .ag-filter-tab--active .ag-filter-count {
    background: rgba(255, 255, 255, 0.12);
    color: var(--text-secondary);
  }

  /* ── Grid ── */

  .ag-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 12px;
  }

  @media (max-width: 720px) {
    .ag-grid {
      grid-template-columns: 1fr;
    }
  }

  /* ── Empty state ── */

  .ag-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 280px;
    gap: 12px;
    color: var(--text-tertiary);
    text-align: center;
    padding: 48px 32px;
  }

  .ag-empty-icon {
    color: rgba(255, 255, 255, 0.12);
    margin-bottom: 4px;
  }

  .ag-empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .ag-empty-sub {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    max-width: 280px;
    line-height: 1.5;
  }
</style>
