<script lang="ts">
  import { signalsStore } from "$lib/stores/signals.svelte";
  import SignalModeBar from "$lib/components/signals/SignalModeBar.svelte";
  import SignalWeightGauge from "$lib/components/signals/SignalWeightGauge.svelte";
  import SignalFeed from "$lib/components/signals/SignalFeed.svelte";
  import SignalFilters from "$lib/components/signals/SignalFilters.svelte";
  import SignalChannelBreakdown from "$lib/components/signals/SignalChannelBreakdown.svelte";
  import SignalTypeBreakdown from "$lib/components/signals/SignalTypeBreakdown.svelte";
  import SignalPatterns from "$lib/components/signals/SignalPatterns.svelte";
  import PageShell from "$lib/components/layout/PageShell.svelte";

  function handleModeSelect(mode: string | undefined): void {
    signalsStore.setFilter('mode', mode);
  }

  function handleFilter(key: string, value: string | undefined): void {
    signalsStore.setFilter(key as 'mode' | 'type' | 'channel', value);
  }

  function handleClearFilters(): void {
    signalsStore.clearFilters();
  }

  // No remote fetch on mount — signals accumulate locally via classifyMessage / addSignal
</script>

<PageShell
  title="Signals"
  subtitle="Signal classification and routing intelligence"
>
  {#snippet actions()}
    <SignalFilters
      filters={signalsStore.filters}
      onFilter={handleFilter}
      onClear={handleClearFilters}
    />

    <button
      class="sig-action-btn"
      onclick={() => { /* signals accumulate locally — nothing to refresh */ }}
      disabled={signalsStore.loading}
      aria-label="Refresh signals"
      title="Refresh"
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
        class:spin={signalsStore.loading}
      >
        <path d="M11 6.5A4.5 4.5 0 002 6.5"/>
        <path d="M11 4.5v2H9"/>
      </svg>
    </button>
  {/snippet}

  <div class="sig-body" id="signals-main">
    {#if signalsStore.error}
      <div class="sig-status-banner" role="status">
        <span class="sig-status-dot" aria-hidden="true"></span>
        <span class="sig-status-text">Backend offline — no signal data</span>
        <button
          class="sig-status-action"
          onclick={() => { signalsStore.error = null; }}
          aria-label="Dismiss error"
        >
          Retry
        </button>
      </div>
    {/if}

    <section class="sig-mode-section">
      <SignalModeBar
        stats={signalsStore.stats}
        activeMode={signalsStore.filters.mode}
        onModeSelect={handleModeSelect}
      />
    </section>

    <div class="sig-content-grid">
      <div class="sig-left-col">
        <div class="sig-panel">
          <SignalWeightGauge stats={signalsStore.stats} />
        </div>

        <div class="sig-panel">
          <SignalChannelBreakdown stats={signalsStore.stats} />
        </div>

        <div class="sig-panel">
          <SignalTypeBreakdown stats={signalsStore.stats} />
        </div>

        <div class="sig-panel">
          <SignalPatterns patterns={signalsStore.patterns} />
        </div>
      </div>

      <div class="sig-right-col">
        <SignalFeed
          signals={signalsStore.liveFeed.length > 0 ? signalsStore.liveFeed : signalsStore.filtered}
          connected={signalsStore.liveConnected}
        />
      </div>
    </div>
  </div>
</PageShell>

<style>
  /* ── Header action button ── */

  .sig-action-btn {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 6px 8px;
    border-radius: var(--radius-sm);
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
    font-size: 0.75rem;
    font-weight: 500;
    transition: all 0.15s;
    white-space: nowrap;
    line-height: 1;
  }

  .sig-action-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .sig-action-btn:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.09);
    border-color: rgba(255, 255, 255, 0.14);
    color: var(--text-primary);
  }

  :global(.spin) {
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* ── Status banner ── */

  .sig-status-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 14px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    flex-shrink: 0;
  }

  .sig-status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .sig-status-text {
    color: var(--text-secondary);
    font-size: 0.7rem;
  }

  .sig-status-action {
    margin-left: auto;
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

  .sig-status-action:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }

  /* ── Body layout ── */

  .sig-body {
    display: flex;
    flex-direction: column;
    gap: 16px;
    /* PageShell ps-content already provides top padding; offset not needed */
  }

  .sig-mode-section {
    flex-shrink: 0;
  }

  .sig-content-grid {
    display: grid;
    grid-template-columns: 1fr 2fr;
    gap: 16px;
    flex: 1;
    min-height: 0;
  }

  .sig-left-col {
    display: flex;
    flex-direction: column;
    gap: 16px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .sig-panel {
    padding: 14px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
  }

  .sig-right-col {
    display: flex;
    flex-direction: column;
    min-height: 0;
    padding: 14px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
  }
</style>
