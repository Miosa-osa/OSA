<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { slide } from 'svelte/transition';
  import { approvalsStore } from '$lib/stores/approvals.svelte';
  import PageShell from '$lib/components/layout/PageShell.svelte';
  import type { Approval, ApprovalStatus } from '$lib/api/types';

  type FilterTab = 'all' | ApprovalStatus;

  const TABS: { id: FilterTab; label: string }[] = [
    { id: 'all',               label: 'All'      },
    { id: 'pending',           label: 'Pending'  },
    { id: 'approved',          label: 'Approved' },
    { id: 'rejected',          label: 'Rejected' },
    { id: 'revision_requested', label: 'Revision' },
  ];

  let activeFilter = $state<FilterTab>('all');
  let pendingActions = $state<Set<number>>(new Set());
  let notesMap = $state<Record<number, string>>({});

  const visibleApprovals = $derived(
    activeFilter === 'all'
      ? approvalsStore.approvals
      : approvalsStore.approvals.filter((a) => a.status === activeFilter),
  );

  function countFor(tab: FilterTab): number {
    if (tab === 'all') return approvalsStore.approvals.length;
    return approvalsStore.approvals.filter((a) => a.status === tab).length;
  }

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

  function typeBadgeLabel(type: Approval['type']): string {
    switch (type) {
      case 'agent_create':    return 'Agent Create';
      case 'budget_change':   return 'Budget';
      case 'task_reassign':   return 'Reassign';
      case 'strategy_change': return 'Strategy';
      case 'agent_terminate': return 'Terminate';
    }
  }

  function getNotes(id: number): string {
    return notesMap[id] ?? '';
  }

  function setNotes(id: number, val: string) {
    notesMap = { ...notesMap, [id]: val };
  }

  async function handleApprove(a: Approval) {
    pendingActions = new Set([...pendingActions, a.id]);
    try {
      await approvalsStore.approve(a.id, getNotes(a.id));
    } finally {
      const next = new Set(pendingActions);
      next.delete(a.id);
      pendingActions = next;
    }
  }

  async function handleReject(a: Approval) {
    pendingActions = new Set([...pendingActions, a.id]);
    try {
      await approvalsStore.reject(a.id, getNotes(a.id));
    } finally {
      const next = new Set(pendingActions);
      next.delete(a.id);
      pendingActions = next;
    }
  }

  async function handleRevision(a: Approval) {
    pendingActions = new Set([...pendingActions, a.id]);
    try {
      await approvalsStore.requestRevision(a.id, getNotes(a.id));
    } finally {
      const next = new Set(pendingActions);
      next.delete(a.id);
      pendingActions = next;
    }
  }

  let pollTimer: ReturnType<typeof setInterval> | null = null;

  onMount(() => {
    approvalsStore.fetchApprovals();
    pollTimer = setInterval(() => approvalsStore.fetchApprovals(), 5000);
  });

  onDestroy(() => {
    if (pollTimer !== null) clearInterval(pollTimer);
  });
</script>

<PageShell title="Approvals">
  {#snippet actions()}
    <!-- Pending badge (only when there are pending items) -->
    {#if approvalsStore.pendingCount > 0}
      <span class="apr-pending-badge" aria-label="{approvalsStore.pendingCount} pending">
        {approvalsStore.pendingCount}
      </span>
    {/if}

    <!-- Stats bar -->
    <div class="apr-stats-bar" role="status" aria-label="Approval statistics">
      <div class="apr-stat apr-stat--pending">
        <span class="apr-stat-dot apr-stat-dot--pending" aria-hidden="true"></span>
        <span class="apr-stat-value">{approvalsStore.pendingCount}</span>
        <span class="apr-stat-label">pending</span>
      </div>
      <div class="apr-stat-divider" aria-hidden="true"></div>
      <div class="apr-stat">
        <span class="apr-stat-value">{approvalsStore.approvals.length}</span>
        <span class="apr-stat-label">total</span>
      </div>
      {#if approvalsStore.loading}
        <span class="apr-loading-spinner" aria-label="Refreshing"></span>
      {/if}
    </div>
  {/snippet}

  {#snippet tabs()}
    {#each TABS as tab (tab.id)}
      <button
        role="tab"
        aria-selected={activeFilter === tab.id}
        class="apr-filter-tab"
        class:apr-filter-tab--active={activeFilter === tab.id}
        onclick={() => activeFilter = tab.id}
      >
        {tab.label}
        {#if countFor(tab.id) > 0}
          <span class="apr-tab-count" class:apr-tab-count--pending={tab.id === 'pending'}>
            {countFor(tab.id)}
          </span>
        {/if}
      </button>
    {/each}
  {/snippet}

  <div id="approvals-main" role="tablist" aria-label="Filter approvals">
    {#if approvalsStore.error}
      <div class="apr-status-banner" role="alert">
        <span class="apr-status-banner-dot"></span>
        <span class="apr-status-banner-text">Backend offline</span>
        <span class="apr-status-banner-hint">Start OSA backend on port 9089</span>
        <button
          class="apr-status-banner-btn"
          onclick={() => approvalsStore.fetchApprovals()}
          aria-label="Retry fetching approvals"
        >
          Retry
        </button>
      </div>
    {/if}

    {#if visibleApprovals.length === 0 && !approvalsStore.loading}
      <div class="apr-empty-state" role="status">
        <div class="apr-empty-icon" aria-hidden="true">
          <svg width="48" height="48" viewBox="0 0 48 48" fill="none">
            <rect x="10" y="8" width="28" height="32" rx="4" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.4"/>
            <line x1="16" y1="18" x2="32" y2="18" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.4"/>
            <line x1="16" y1="24" x2="28" y2="24" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.25"/>
            <line x1="16" y1="30" x2="24" y2="30" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.15"/>
          </svg>
        </div>
        <p class="apr-empty-title">No approvals</p>
        <p class="apr-empty-subtitle">Approval requests from agents will appear here.</p>
      </div>
    {:else}
      <div class="apr-approvals-list" role="list" aria-label="Approval list">
        {#each visibleApprovals as approval (approval.id)}
          <article
            class="apr-approval-card"
            class:apr-approval-card--pending={approval.status === 'pending'}
            class:apr-approval-card--approved={approval.status === 'approved'}
            class:apr-approval-card--rejected={approval.status === 'rejected'}
            class:apr-approval-card--revision={approval.status === 'revision_requested'}
            role="listitem"
            transition:slide={{ duration: 180 }}
          >
            <div class="apr-card-top">
              <div class="apr-card-top-left">
                <span
                  class="apr-status-dot"
                  class:apr-status-dot--pending={approval.status === 'pending'}
                  class:apr-status-dot--approved={approval.status === 'approved'}
                  class:apr-status-dot--rejected={approval.status === 'rejected'}
                  class:apr-status-dot--revision={approval.status === 'revision_requested'}
                  aria-hidden="true"
                ></span>
                <span class="apr-type-badge">{typeBadgeLabel(approval.type)}</span>
              </div>
              <time class="apr-card-time" datetime={approval.inserted_at}>
                {formatRelative(approval.inserted_at)}
              </time>
            </div>

            <h2 class="apr-card-title">{approval.title}</h2>

            {#if approval.description}
              <p class="apr-card-description">{approval.description}</p>
            {/if}

            <div class="apr-card-meta">
              <span class="apr-meta-label">Requested by</span>
              <span class="apr-meta-value">{approval.requested_by}</span>
            </div>

            {#if approval.status === 'pending'}
              <div class="apr-card-actions" transition:slide={{ duration: 140 }}>
                <textarea
                  class="apr-notes-input"
                  placeholder="Optional notes..."
                  rows="2"
                  value={getNotes(approval.id)}
                  oninput={(e) => setNotes(approval.id, (e.currentTarget as HTMLTextAreaElement).value)}
                  aria-label="Decision notes for approval {approval.id}"
                ></textarea>
                <div class="apr-action-btns">
                  <button
                    class="apr-action-btn apr-action-btn--approve"
                    onclick={() => handleApprove(approval)}
                    disabled={pendingActions.has(approval.id)}
                    aria-label="Approve: {approval.title}"
                  >
                    Approve
                  </button>
                  <button
                    class="apr-action-btn apr-action-btn--revision"
                    onclick={() => handleRevision(approval)}
                    disabled={pendingActions.has(approval.id)}
                    aria-label="Request revision for: {approval.title}"
                  >
                    Request Revision
                  </button>
                  <button
                    class="apr-action-btn apr-action-btn--reject"
                    onclick={() => handleReject(approval)}
                    disabled={pendingActions.has(approval.id)}
                    aria-label="Reject: {approval.title}"
                  >
                    Reject
                  </button>
                </div>
              </div>
            {:else}
              <div class="apr-resolution-row">
                {#if approval.resolved_by}
                  <div class="apr-card-meta">
                    <span class="apr-meta-label">Resolved by</span>
                    <span class="apr-meta-value">{approval.resolved_by}</span>
                  </div>
                {/if}
                {#if approval.resolved_at}
                  <div class="apr-card-meta">
                    <span class="apr-meta-label">Resolved</span>
                    <time class="apr-meta-value" datetime={approval.resolved_at}>
                      {formatRelative(approval.resolved_at)}
                    </time>
                  </div>
                {/if}
                {#if approval.decision_notes}
                  <p class="apr-decision-notes">{approval.decision_notes}</p>
                {/if}
              </div>
            {/if}
          </article>
        {/each}
      </div>
    {/if}
  </div>
</PageShell>

<style>
  /* ── Pending badge ── */

  .apr-pending-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 20px;
    height: 20px;
    padding: 0 6px;
    border-radius: var(--radius-full);
    background: rgba(251, 191, 36, 0.18);
    color: rgba(251, 191, 36, 0.9);
    border: 1px solid rgba(251, 191, 36, 0.25);
    font-size: 0.6875rem;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }

  /* ── Stats bar ── */

  .apr-stats-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    padding: 6px 14px;
  }

  .apr-stat {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  .apr-stat--pending .apr-stat-value {
    color: rgba(251, 191, 36, 0.9);
  }

  .apr-stat-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-tertiary);
  }

  .apr-stat-dot--pending {
    background: rgba(251, 191, 36, 0.8);
    animation: pulse-dot 2s ease-in-out infinite;
  }

  @keyframes pulse-dot {
    0%, 100% { opacity: 1; transform: scale(1); }
    50%       { opacity: 0.6; transform: scale(0.8); }
  }

  .apr-stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  .apr-stat-label {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .apr-stat-divider {
    width: 1px;
    height: 12px;
    background: rgba(255, 255, 255, 0.08);
  }

  .apr-loading-spinner {
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

  /* ── Filter tabs (rendered inside ps-tabs-strip) ── */

  .apr-filter-tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 12px;
    border-radius: var(--radius-md);
    border: none;
    background: none;
    color: var(--text-tertiary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
    line-height: 1;
  }

  .apr-filter-tab:hover:not(.apr-filter-tab--active) {
    background: rgba(255, 255, 255, 0.04);
    color: var(--text-secondary);
  }

  .apr-filter-tab--active {
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-primary);
  }

  .apr-tab-count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 18px;
    height: 18px;
    padding: 0 5px;
    border-radius: var(--radius-full);
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-tertiary);
    font-size: 0.625rem;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }

  .apr-tab-count--pending {
    background: rgba(251, 191, 36, 0.14);
    color: rgba(251, 191, 36, 0.85);
  }

  /* ── Status banner ── */

  .apr-status-banner {
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

  .apr-status-banner-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .apr-status-banner-text {
    color: var(--text-secondary);
  }

  .apr-status-banner-hint {
    margin-left: auto;
    color: var(--text-muted);
  }

  .apr-status-banner-btn {
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

  .apr-status-banner-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }

  /* ── Empty state ── */

  .apr-empty-state {
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

  .apr-empty-icon {
    color: rgba(255, 255, 255, 0.12);
    margin-bottom: 4px;
  }

  .apr-empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .apr-empty-subtitle {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    max-width: 280px;
    line-height: 1.5;
  }

  /* ── Approvals list ── */

  .apr-approvals-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  /* ── Approval card ── */

  .apr-approval-card {
    background: rgba(255, 255, 255, 0.04);
    backdrop-filter: blur(24px);
    -webkit-backdrop-filter: blur(24px);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    transition: border-color 0.2s ease, box-shadow 0.2s ease;
  }

  .apr-approval-card--pending {
    border-color: rgba(251, 191, 36, 0.2);
    box-shadow:
      0 0 0 1px rgba(251, 191, 36, 0.06),
      inset 0 1px 0 rgba(251, 191, 36, 0.04);
  }

  .apr-approval-card--approved {
    border-color: rgba(34, 197, 94, 0.15);
    opacity: 0.8;
  }

  .apr-approval-card--rejected {
    border-color: rgba(239, 68, 68, 0.15);
    opacity: 0.75;
  }

  .apr-approval-card--revision {
    border-color: rgba(249, 115, 22, 0.2);
  }

  /* ── Card top row ── */

  .apr-card-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .apr-card-top-left {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  /* ── Status dot ── */

  .apr-status-dot {
    display: block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.2);
    flex-shrink: 0;
  }

  .apr-status-dot--pending {
    background: rgba(251, 191, 36, 0.85);
    box-shadow: 0 0 6px rgba(251, 191, 36, 0.4);
    animation: pulse-glow-yellow 2s ease-in-out infinite;
  }

  .apr-status-dot--approved {
    background: var(--accent-success);
    box-shadow: 0 0 6px rgba(34, 197, 94, 0.4);
  }

  .apr-status-dot--rejected {
    background: var(--accent-error);
    box-shadow: 0 0 4px rgba(239, 68, 68, 0.3);
  }

  .apr-status-dot--revision {
    background: rgba(249, 115, 22, 0.85);
    box-shadow: 0 0 6px rgba(249, 115, 22, 0.35);
  }

  @keyframes pulse-glow-yellow {
    0%, 100% { box-shadow: 0 0 4px rgba(251, 191, 36, 0.3); }
    50%       { box-shadow: 0 0 10px rgba(251, 191, 36, 0.65); }
  }

  /* ── Type badge ── */

  .apr-type-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: var(--radius-full);
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    background: rgba(255, 255, 255, 0.07);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  .apr-card-time {
    font-size: 0.75rem;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
    flex-shrink: 0;
  }

  /* ── Card body ── */

  .apr-card-title {
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--text-primary);
    line-height: 1.3;
  }

  .apr-card-description {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.5;
  }

  .apr-card-meta {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .apr-meta-label {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .apr-meta-value {
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  /* ── Pending actions ── */

  .apr-card-actions {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding-top: 4px;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
  }

  .apr-notes-input {
    width: 100%;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md);
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-family: inherit;
    padding: 8px 10px;
    resize: vertical;
    outline: none;
    transition: border-color 0.15s;
    box-sizing: border-box;
  }

  .apr-notes-input::placeholder {
    color: var(--text-muted);
  }

  .apr-notes-input:focus {
    border-color: rgba(255, 255, 255, 0.16);
  }

  .apr-action-btns {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
  }

  .apr-action-btn {
    padding: 6px 14px;
    border-radius: var(--radius-md);
    border: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
  }

  .apr-action-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .apr-action-btn--approve {
    background: rgba(34, 197, 94, 0.1);
    border-color: rgba(34, 197, 94, 0.2);
    color: rgba(34, 197, 94, 0.9);
  }

  .apr-action-btn--approve:hover:not(:disabled) {
    background: rgba(34, 197, 94, 0.18);
    border-color: rgba(34, 197, 94, 0.35);
  }

  .apr-action-btn--reject {
    background: rgba(239, 68, 68, 0.08);
    border-color: rgba(239, 68, 68, 0.18);
    color: rgba(239, 68, 68, 0.85);
  }

  .apr-action-btn--reject:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.15);
    border-color: rgba(239, 68, 68, 0.3);
  }

  .apr-action-btn--revision {
    background: rgba(249, 115, 22, 0.08);
    border-color: rgba(249, 115, 22, 0.18);
    color: rgba(249, 115, 22, 0.85);
  }

  .apr-action-btn--revision:hover:not(:disabled) {
    background: rgba(249, 115, 22, 0.15);
    border-color: rgba(249, 115, 22, 0.3);
  }

  /* ── Resolution section ── */

  .apr-resolution-row {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding-top: 4px;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
  }

  .apr-decision-notes {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    line-height: 1.5;
    font-style: italic;
    padding: 6px 10px;
    background: rgba(255, 255, 255, 0.025);
    border-radius: var(--radius-sm);
    border: 1px solid rgba(255, 255, 255, 0.05);
  }
</style>
