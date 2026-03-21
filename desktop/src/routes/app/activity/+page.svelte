<script lang="ts">
  import { onMount } from "svelte";
  import { activityLogsStore } from "$lib/stores/activityLogs.svelte";
  import ActivityFilters from "$lib/components/activity/ActivityFilters.svelte";
  import ActivityTable from "$lib/components/activity/ActivityTable.svelte";
  import PageShell from "$lib/components/layout/PageShell.svelte";

  // ── Actions ───────────────────────────────────────────────────────────────

  let exportPending = $state(false);
  let clearConfirm = $state(false);
  let clearConfirmTimer: ReturnType<typeof setTimeout> | null = null;

  function handleExport(): void {
    exportPending = true;
    try {
      const json = activityLogsStore.exportLogs();
      const blob = new Blob([json], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `osa-logs-${new Date()
        .toISOString()
        .slice(0, 19)
        .replace(/:/g, "-")}.json`;
      a.click();
      URL.revokeObjectURL(url);
    } finally {
      exportPending = false;
    }
  }

  function handleClearAll(): void {
    if (!clearConfirm) {
      // First click — show confirmation state for 2.5s
      clearConfirm = true;
      clearConfirmTimer = setTimeout(() => {
        clearConfirm = false;
      }, 2500);
      return;
    }
    // Second click within window — confirm
    if (clearConfirmTimer !== null) clearTimeout(clearConfirmTimer);
    clearConfirm = false;
    activityLogsStore.clearLogs();
    activityLogsStore.clearFilters();
  }

  // ── Mount ─────────────────────────────────────────────────────────────────

  onMount(() => {
    activityLogsStore.fetchLogs();
  });
</script>

<PageShell
  title="Activity Logs"
  subtitle="System events and agent activity"
>
  {#snippet actions()}
    <!-- Export JSON -->
    <button
      class="act-action-btn act-action-btn--secondary"
      onclick={handleExport}
      disabled={exportPending || activityLogsStore.filtered.length === 0}
      aria-label="Export filtered logs as JSON"
    >
      <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M6.5 1.5v7M4 6.5l2.5 2.5L9 6.5"/>
        <path d="M2 10.5v.5a1 1 0 001 1h7a1 1 0 001-1v-.5"/>
      </svg>
      Export JSON
    </button>

    <!-- Clear All (double-click to confirm) -->
    <button
      class="act-action-btn"
      class:act-action-btn--danger={clearConfirm}
      class:act-action-btn--secondary={!clearConfirm}
      onclick={handleClearAll}
      disabled={activityLogsStore.logs.length === 0}
      aria-label={clearConfirm ? "Confirm clear all logs" : "Clear all logs"}
    >
      {#if clearConfirm}
        <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
          <polyline points="1.5,7 4.5,10 11,3"/>
        </svg>
        Confirm Clear
      {:else}
        <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <polyline points="2,3 11,3"/>
          <path d="M4.5 3V2a.5.5 0 01.5-.5h3a.5.5 0 01.5.5v1"/>
          <path d="M3.5 3l.5 8h5.5l.5-8"/>
          <line x1="6.5" y1="5.5" x2="6.5" y2="8.5"/>
          <line x1="4.5" y1="5.5" x2="4.75" y2="8.5"/>
          <line x1="8.5" y1="5.5" x2="8.25" y2="8.5"/>
        </svg>
        Clear All
      {/if}
    </button>

    <!-- Refresh -->
    <button
      class="act-action-btn act-action-btn--secondary act-action-btn--icon"
      onclick={() => activityLogsStore.fetchLogs()}
      disabled={activityLogsStore.loading}
      aria-label="Refresh logs"
      title="Refresh logs"
    >
      <svg
        width="13"
        height="13"
        viewBox="0 0 13 13"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
        class:spin={activityLogsStore.loading}
      >
        <path d="M11 6.5A4.5 4.5 0 002 6.5"/>
        <path d="M11 4.5v2H9"/>
      </svg>
    </button>
  {/snippet}

  <div class="act-content" id="activity-main">
    <!-- Error banner (subtle, non-blocking) -->
    {#if activityLogsStore.error}
      <div class="act-status-banner" role="status">
        <span class="act-status-dot" aria-hidden="true"></span>
        <span class="act-status-text">Backend offline — showing cached data</span>
        <span class="act-status-hint">Start OSA backend on port 9089</span>
        <button
          class="act-status-action"
          onclick={() => activityLogsStore.fetchLogs()}
          aria-label="Retry fetching logs"
        >
          Retry
        </button>
      </div>
    {/if}

    <!-- Filters -->
    <ActivityFilters
      filterLevel={activityLogsStore.filterLevel}
      filterSource={activityLogsStore.filterSource}
      searchQuery={activityLogsStore.searchQuery}
      totalCount={activityLogsStore.totalCount}
      filteredCount={activityLogsStore.filteredCount}
      onFilterLevel={(level) => activityLogsStore.setFilter("level", level)}
      onFilterSource={(source) => activityLogsStore.setFilter("source", source)}
      onSearch={(q) => activityLogsStore.setSearch(q)}
      onClear={() => activityLogsStore.clearFilters()}
    />

    <!-- Log table -->
    <ActivityTable
      logs={activityLogsStore.filtered}
      loading={activityLogsStore.loading}
    />
  </div>
</PageShell>

<style>
  /* ── Header action buttons ── */

  .act-action-btn {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 6px 12px;
    border-radius: var(--radius-sm);
    border: 1px solid transparent;
    font-size: 0.75rem;
    font-weight: 500;
    transition: all 0.15s;
    white-space: nowrap;
    line-height: 1;
  }

  .act-action-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .act-action-btn--secondary {
    background: rgba(255, 255, 255, 0.05);
    border-color: rgba(255, 255, 255, 0.08);
    color: var(--text-secondary);
  }

  .act-action-btn--secondary:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.09);
    border-color: rgba(255, 255, 255, 0.14);
    color: var(--text-primary);
  }

  .act-action-btn--danger {
    background: rgba(239, 68, 68, 0.12);
    border-color: rgba(239, 68, 68, 0.22);
    color: rgba(252, 100, 100, 0.9);
  }

  .act-action-btn--danger:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.18);
    border-color: rgba(239, 68, 68, 0.35);
  }

  .act-action-btn--icon {
    padding: 6px 8px;
  }

  /* ── Refresh spinner ── */

  :global(.spin) {
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* ── Content wrapper ── */

  .act-content {
    display: flex;
    flex-direction: column;
    gap: 0;
  }

  /* ── Status banner ── */

  .act-status-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 14px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    margin-bottom: 4px;
    flex-shrink: 0;
  }

  .act-status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .act-status-text {
    color: var(--text-secondary);
    font-size: 0.7rem;
  }

  .act-status-hint {
    margin-left: auto;
    color: var(--text-muted);
  }

  .act-status-action {
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .act-status-action:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }
</style>
