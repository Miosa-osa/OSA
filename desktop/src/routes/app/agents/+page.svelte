<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { agentsStore } from '$lib/stores/agents.svelte';
  import { agents as agentsApi, hierarchy as hierarchyApi } from '$lib/api/client';
  import { restartBackend } from '$lib/utils/backend';
  import type { Agent, HierarchyNode } from '$lib/api/types';
  import AgentGrid from '$lib/components/agents/AgentGrid.svelte';
  import AgentTree from '$lib/components/agents/AgentTree.svelte';
  import OrgChart from '$lib/components/agents/OrgChart.svelte';

  // ── View mode ────────────────────────────────────────────────────────────────

  type ViewMode = 'grid' | 'tree' | 'org';

  function loadViewMode(): ViewMode {
    try {
      const stored = localStorage.getItem('osa:agents:view');
      if (stored === 'tree' || stored === 'grid' || stored === 'org') return stored;
    } catch { /* ignore */ }
    return 'grid';
  }

  let viewMode = $state<ViewMode>(loadViewMode());

  function setViewMode(mode: ViewMode) {
    viewMode = mode;
    try {
      localStorage.setItem('osa:agents:view', mode);
    } catch { /* ignore */ }
    if (mode === 'org') fetchHierarchy();
  }

  // ── Hierarchy ────────────────────────────────────────────────────────────────

  let hierarchyTree = $state<HierarchyNode[]>([]);
  let hierarchyLoading = $state(false);

  async function fetchHierarchy() {
    hierarchyLoading = true;
    try {
      hierarchyTree = await hierarchyApi.getTree();
    } catch { hierarchyTree = []; }
    finally { hierarchyLoading = false; }
  }

  async function handleMove(agentName: string, newReportsTo: string | null) {
    await hierarchyApi.update(agentName, { reports_to: newReportsTo });
    await fetchHierarchy();
  }

  async function seedHierarchy() {
    await hierarchyApi.seed();
    await fetchHierarchy();
  }

  // ── Polling ──────────────────────────────────────────────────────────────────

  let pollTimer: ReturnType<typeof setInterval> | null = null;

  onMount(() => {
    agentsStore.fetchAgents();
    if (viewMode === 'org') fetchHierarchy();
    pollTimer = setInterval(() => agentsStore.fetchAgents(), 5000);
  });

  onDestroy(() => {
    if (pollTimer !== null) clearInterval(pollTimer);
  });

  // ── Optimistic actions ───────────────────────────────────────────────────────

  let pendingIds = $state<Set<string>>(new Set());

  async function handlePause(agent: Agent) {
    pendingIds = new Set([...pendingIds, agent.id]);
    try {
      await agentsApi.pause(agent.id);
      agentsStore.setAgentStatus(agent.id, 'idle');
    } catch { /* next poll corrects state */ }
    finally {
      const next = new Set(pendingIds);
      next.delete(agent.id);
      pendingIds = next;
    }
  }

  async function handleCancel(agent: Agent) {
    pendingIds = new Set([...pendingIds, agent.id]);
    try {
      await agentsApi.cancel(agent.id);
      agentsStore.setAgentStatus(agent.id, 'idle');
    } catch { /* next poll corrects state */ }
    finally {
      const next = new Set(pendingIds);
      next.delete(agent.id);
      pendingIds = next;
    }
  }

  // ── Relative time (header only) ──────────────────────────────────────────────

  function formatRelative(iso: string): string {
    const diff = Date.now() - new Date(iso).getTime();
    const s = Math.floor(diff / 1000);
    if (s < 60) return 'just now';
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m ago`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h}h ago`;
    return `${Math.floor(h / 24)}d ago`;
  }
</script>

<!-- ── Page shell ── -->
<div class="agents-page">

  <!-- ── Header ── -->
  <header class="page-header">
    <div class="header-left">
      <h1 class="page-title">Agents</h1>
      {#if agentsStore.lastUpdated}
        <span class="last-updated" aria-live="polite">
          Updated {formatRelative(agentsStore.lastUpdated.toISOString())}
        </span>
      {/if}
    </div>

    <!-- View mode toggle -->
    <div class="view-toggle" role="group" aria-label="View mode">
      <button
        class="view-btn"
        class:view-btn--active={viewMode === 'grid'}
        onclick={() => setViewMode('grid')}
        aria-pressed={viewMode === 'grid'}
        aria-label="Grid view"
        title="Grid view"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="currentColor" aria-hidden="true">
          <rect x="1" y="1" width="5" height="5" rx="1.5"/>
          <rect x="8" y="1" width="5" height="5" rx="1.5"/>
          <rect x="1" y="8" width="5" height="5" rx="1.5"/>
          <rect x="8" y="8" width="5" height="5" rx="1.5"/>
        </svg>
        <span class="view-btn-label">Grid</span>
      </button>
      <button
        class="view-btn"
        class:view-btn--active={viewMode === 'tree'}
        onclick={() => setViewMode('tree')}
        aria-pressed={viewMode === 'tree'}
        aria-label="Tree view"
        title="Tree view"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
          <circle cx="7" cy="2.5" r="1.5" fill="currentColor" stroke="none"/>
          <circle cx="3" cy="11" r="1.5" fill="currentColor" stroke="none"/>
          <circle cx="11" cy="11" r="1.5" fill="currentColor" stroke="none"/>
          <line x1="7" y1="4" x2="3" y2="9.5"/>
          <line x1="7" y1="4" x2="11" y2="9.5"/>
        </svg>
        <span class="view-btn-label">Tree</span>
      </button>
      <button
        class="view-btn"
        class:view-btn--active={viewMode === 'org'}
        onclick={() => setViewMode('org')}
        aria-pressed={viewMode === 'org'}
        aria-label="Org chart view"
        title="Org chart view"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
          <rect x="4.5" y="1" width="5" height="3" rx="1" fill="currentColor" stroke="none"/>
          <rect x="0.5" y="9" width="4" height="3" rx="1" fill="currentColor" stroke="none" opacity="0.6"/>
          <rect x="9.5" y="9" width="4" height="3" rx="1" fill="currentColor" stroke="none" opacity="0.6"/>
          <line x1="7" y1="4" x2="7" y2="6.5"/>
          <line x1="2.5" y1="9" x2="2.5" y2="6.5"/>
          <line x1="11.5" y1="9" x2="11.5" y2="6.5"/>
          <line x1="2.5" y1="6.5" x2="11.5" y2="6.5"/>
        </svg>
        <span class="view-btn-label">Org</span>
      </button>
    </div>

    <!-- Stats bar -->
    <div class="stats-bar" role="status" aria-label="Agent statistics">
      <div class="stat stat--running">
        <span class="stat-dot stat-dot--running" aria-hidden="true"></span>
        <span class="stat-value">{agentsStore.runningCount}</span>
        <span class="stat-label">running</span>
      </div>
      <div class="stat-divider" aria-hidden="true"></div>
      <div class="stat">
        <span class="stat-value">{agentsStore.completedCount}</span>
        <span class="stat-label">done</span>
      </div>
      <div class="stat-divider" aria-hidden="true"></div>
      {#if agentsStore.failedCount > 0}
        <div class="stat stat--error">
          <span class="stat-value">{agentsStore.failedCount}</span>
          <span class="stat-label">failed</span>
        </div>
        <div class="stat-divider" aria-hidden="true"></div>
      {/if}
      <div class="stat">
        <span class="stat-value">{agentsStore.totalCount}</span>
        <span class="stat-label">total</span>
      </div>
      {#if agentsStore.loading}
        <span class="loading-spinner" aria-label="Refreshing"></span>
      {/if}
    </div>
  </header>

  <!-- ── Content ── -->
  <main class="page-content" id="agents-main">

    {#if agentsStore.error}
      <div class="status-banner" role="status">
        <span class="status-banner-dot"></span>
        <span class="status-banner-text">Backend offline</span>
        <span class="status-banner-hint">Start OSA backend on port 9089</span>
        <button
          class="status-banner-btn"
          onclick={() => { restartBackend().catch(() => {}); }}
          aria-label="Restart backend"
        >
          Restart
        </button>
        <button
          class="status-banner-btn"
          onclick={() => agentsStore.fetchAgents()}
          aria-label="Retry fetching agents"
        >
          Retry
        </button>
      </div>
    {/if}

    {#if viewMode === 'org'}
      {#if hierarchyTree.length === 0 && !hierarchyLoading}
        <div class="empty-state" role="status">
          <p class="empty-title">No hierarchy configured</p>
          <p class="empty-subtitle">Seed the default org structure to get started.</p>
          <button class="seed-btn" onclick={seedHierarchy}>Seed Default Hierarchy</button>
        </div>
      {:else}
        <OrgChart tree={hierarchyTree} onMove={handleMove} />
      {/if}

    {:else if viewMode === 'tree'}
      <AgentTree />

    {:else}
      <AgentGrid
        agents={agentsStore.agents}
        {pendingIds}
        onPause={handlePause}
        onCancel={handleCancel}
      />
    {/if}
  </main>
</div>

<style>
  /* ── Page layout ── */

  .agents-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  /* ── Header ── */

  .page-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 24px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
    gap: 16px;
    flex-wrap: wrap;
  }

  .header-left {
    display: flex;
    align-items: baseline;
    gap: 12px;
  }

  .page-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
  }

  .last-updated {
    font-size: 0.75rem;
    color: var(--text-tertiary);
  }

  /* ── View toggle ── */

  .view-toggle {
    display: flex;
    align-items: center;
    gap: 2px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-md);
    padding: 3px;
  }

  .view-btn {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 4px 9px;
    border-radius: calc(var(--radius-md) - 3px);
    border: none;
    background: none;
    color: var(--text-tertiary);
    font-size: 0.75rem;
    font-weight: 500;
    transition: all 0.15s;
    line-height: 1;
    cursor: pointer;
  }

  .view-btn:hover:not(.view-btn--active) {
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
  }

  .view-btn--active {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text-primary);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.2);
  }

  .view-btn-label {
    font-size: 0.6875rem;
    letter-spacing: 0.02em;
  }

  /* ── Stats bar ── */

  .stats-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    padding: 6px 14px;
  }

  .stat {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  .stat--running .stat-value { color: var(--accent-success); }
  .stat--error .stat-value   { color: var(--accent-error); }

  .stat-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-tertiary);
  }

  .stat-dot--running {
    background: var(--accent-success);
    animation: pulse-dot 2s ease-in-out infinite;
  }

  @keyframes pulse-dot {
    0%, 100% { opacity: 1; transform: scale(1); }
    50%       { opacity: 0.6; transform: scale(0.8); }
  }

  .stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  .stat-label {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .stat-divider {
    width: 1px;
    height: 12px;
    background: rgba(255, 255, 255, 0.08);
  }

  .loading-spinner {
    width: 12px;
    height: 12px;
    border: 1.5px solid rgba(255, 255, 255, 0.1);
    border-top-color: rgba(255, 255, 255, 0.5);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    flex-shrink: 0;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* ── Content ── */

  .page-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  /* ── Status banner ── */

  .status-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    margin-bottom: 16px;
  }

  .status-banner-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .status-banner-text  { color: var(--text-secondary); }
  .status-banner-hint  { margin-left: auto; color: var(--text-muted); }

  .status-banner-btn {
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .status-banner-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }

  /* ── Empty state (org chart only) ── */

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 320px;
    gap: 12px;
    color: var(--text-tertiary);
    text-align: center;
    padding: 48px 32px;
  }

  .empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .empty-subtitle {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    max-width: 280px;
    line-height: 1.5;
  }

  .seed-btn {
    margin-top: 8px;
    padding: 8px 20px;
    border-radius: var(--radius-md);
    background: rgba(59, 130, 246, 0.12);
    border: 1px solid rgba(59, 130, 246, 0.25);
    color: rgba(59, 130, 246, 0.9);
    font-size: 0.8125rem;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
  }

  .seed-btn:hover {
    background: rgba(59, 130, 246, 0.2);
    border-color: rgba(59, 130, 246, 0.4);
  }
</style>
