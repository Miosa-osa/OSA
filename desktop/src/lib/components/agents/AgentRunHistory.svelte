<!-- src/lib/components/agents/AgentRunHistory.svelte -->
<!-- Runs tab: cost events as execution history, newest first, expandable rows. -->
<script lang="ts">
  import { slide } from 'svelte/transition';
  import type { CostEvent } from '$lib/api/types';

  interface Props {
    agentName: string;
    costEvents: CostEvent[];
  }

  let { agentName, costEvents }: Props = $props();

  let expandedId = $state<number | null>(null);

  const sortedEvents = $derived(
    [...costEvents].sort((a, b) =>
      new Date(b.inserted_at).getTime() - new Date(a.inserted_at).getTime()
    )
  );

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleString(undefined, {
      dateStyle: 'short',
      timeStyle: 'short',
    });
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

  function formatTokens(n: number): string {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
    if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
    return String(n);
  }

  function formatCost(cents: number): string {
    if (cents === 0) return '$0.00';
    if (cents < 1) return `$0.0${Math.round(cents * 10)}`;
    return `$${(cents / 100).toFixed(4)}`;
  }

  function toggleExpand(id: number) {
    expandedId = expandedId === id ? null : id;
  }

  const totalTokens = $derived(
    costEvents.reduce((sum, e) => sum + e.input_tokens + e.output_tokens, 0)
  );

  const totalCost = $derived(
    costEvents.reduce((sum, e) => sum + e.cost_cents, 0)
  );
</script>

<div class="arh-root">

  <!-- ── Summary strip ── -->
  {#if costEvents.length > 0}
    <div class="arh-summary" aria-label="Run history summary">
      <div class="arh-summary-cell">
        <span class="arh-summary-label">Total Runs</span>
        <span class="arh-summary-value">{costEvents.length}</span>
      </div>
      <div class="arh-summary-divider" aria-hidden="true"></div>
      <div class="arh-summary-cell">
        <span class="arh-summary-label">Total Tokens</span>
        <span class="arh-summary-value">{formatTokens(totalTokens)}</span>
      </div>
      <div class="arh-summary-divider" aria-hidden="true"></div>
      <div class="arh-summary-cell">
        <span class="arh-summary-label">Total Cost</span>
        <span class="arh-summary-value">{formatCost(totalCost)}</span>
      </div>
    </div>
  {/if}

  <!-- ── Run list ── -->
  {#if sortedEvents.length === 0}
    <div class="arh-empty" role="status">
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="opacity: 0.2">
        <rect x="3" y="4" width="18" height="18" rx="2" ry="2"/>
        <line x1="16" y1="2" x2="16" y2="6"/>
        <line x1="8" y1="2" x2="8" y2="6"/>
        <line x1="3" y1="10" x2="21" y2="10"/>
      </svg>
      <p class="arh-empty-title">No run history</p>
      <p class="arh-empty-sub">Execution cost events for <strong>{agentName}</strong> will appear here.</p>
    </div>

  {:else}
    <div class="arh-list" role="list" aria-label="Run history">
      {#each sortedEvents as event (event.id)}
        <article
          class="arh-row"
          class:arh-row--expanded={expandedId === event.id}
          role="listitem"
        >
          <!-- ── Row header ── -->
          <button
            class="arh-row-header"
            onclick={() => toggleExpand(event.id)}
            aria-expanded={expandedId === event.id}
            aria-label="Run at {formatDate(event.inserted_at)}, {formatTokens(event.input_tokens + event.output_tokens)} tokens"
          >
            <div class="arh-row-left">
              <span class="arh-run-dot" aria-hidden="true"></span>
              <div class="arh-run-info">
                <span class="arh-run-model">{event.model}</span>
                <span class="arh-run-time">{formatRelative(event.inserted_at)}</span>
              </div>
            </div>
            <div class="arh-row-right">
              <div class="arh-run-metric">
                <span class="arh-metric-label">Tokens</span>
                <span class="arh-metric-value">{formatTokens(event.input_tokens + event.output_tokens)}</span>
              </div>
              <div class="arh-run-metric">
                <span class="arh-metric-label">Cost</span>
                <span class="arh-metric-value">{formatCost(event.cost_cents)}</span>
              </div>
              <span class="arh-chevron" class:arh-chevron--open={expandedId === event.id} aria-hidden="true">›</span>
            </div>
          </button>

          <!-- ── Expanded detail ── -->
          {#if expandedId === event.id}
            <div
              class="arh-detail"
              transition:slide={{ duration: 180 }}
            >
              <div class="arh-detail-divider" aria-hidden="true"></div>
              <dl class="arh-detail-grid">
                <div class="arh-detail-item">
                  <dt>Provider</dt>
                  <dd>{event.provider}</dd>
                </div>
                <div class="arh-detail-item">
                  <dt>Model</dt>
                  <dd>{event.model}</dd>
                </div>
                <div class="arh-detail-item">
                  <dt>Input Tokens</dt>
                  <dd>{formatTokens(event.input_tokens)}</dd>
                </div>
                <div class="arh-detail-item">
                  <dt>Output Tokens</dt>
                  <dd>{formatTokens(event.output_tokens)}</dd>
                </div>
                {#if event.cache_read_tokens > 0}
                  <div class="arh-detail-item">
                    <dt>Cache Read</dt>
                    <dd>{formatTokens(event.cache_read_tokens)}</dd>
                  </div>
                {/if}
                {#if event.cache_write_tokens > 0}
                  <div class="arh-detail-item">
                    <dt>Cache Write</dt>
                    <dd>{formatTokens(event.cache_write_tokens)}</dd>
                  </div>
                {/if}
                <div class="arh-detail-item">
                  <dt>Cost</dt>
                  <dd class="arh-detail-cost">{formatCost(event.cost_cents)}</dd>
                </div>
                <div class="arh-detail-item">
                  <dt>Timestamp</dt>
                  <dd>{formatDate(event.inserted_at)}</dd>
                </div>
                {#if event.session_id}
                  <div class="arh-detail-item">
                    <dt>Session ID</dt>
                    <dd><code class="arh-mono">{event.session_id}</code></dd>
                  </div>
                {/if}
                {#if event.task_id}
                  <div class="arh-detail-item">
                    <dt>Task ID</dt>
                    <dd><code class="arh-mono">{event.task_id}</code></dd>
                  </div>
                {/if}
              </dl>
            </div>
          {/if}
        </article>
      {/each}
    </div>
  {/if}

</div>

<style>
  .arh-root {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  /* ── Summary ── */

  .arh-summary {
    display: flex;
    align-items: center;
    gap: 0;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
    overflow: hidden;
  }

  .arh-summary-cell {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 3px;
    padding: 12px 16px;
  }

  .arh-summary-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .arh-summary-value {
    font-size: 1rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  .arh-summary-divider {
    width: 1px;
    height: 40px;
    background: rgba(255, 255, 255, 0.06);
    flex-shrink: 0;
  }

  /* ── Empty ── */

  .arh-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 64px 32px;
    gap: 10px;
    text-align: center;
    background: rgba(255, 255, 255, 0.02);
    border: 1px dashed rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
  }

  .arh-empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .arh-empty-sub {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    max-width: 280px;
    line-height: 1.5;
  }

  .arh-empty-sub strong {
    color: var(--text-secondary);
    font-weight: 500;
  }

  /* ── Row list ── */

  .arh-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .arh-row {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
    overflow: hidden;
    transition: border-color 0.15s;
  }

  .arh-row--expanded {
    border-color: rgba(255, 255, 255, 0.11);
  }

  /* ── Row header ── */

  .arh-row-header {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 14px;
    background: none;
    border: none;
    cursor: pointer;
    gap: 12px;
    text-align: left;
    transition: background 0.15s;
  }

  .arh-row-header:hover {
    background: rgba(255, 255, 255, 0.03);
  }

  .arh-row-left {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
    flex: 1;
  }

  .arh-run-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: rgba(59, 130, 246, 0.5);
    flex-shrink: 0;
  }

  .arh-run-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .arh-run-model {
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .arh-run-time {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
  }

  .arh-row-right {
    display: flex;
    align-items: center;
    gap: 14px;
    flex-shrink: 0;
  }

  .arh-run-metric {
    display: flex;
    flex-direction: column;
    gap: 2px;
    align-items: flex-end;
  }

  .arh-metric-label {
    font-size: 0.5625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .arh-metric-value {
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .arh-chevron {
    font-size: 1rem;
    color: rgba(255, 255, 255, 0.25);
    transition: transform 0.18s ease;
    display: inline-block;
    line-height: 1;
  }

  .arh-chevron--open {
    transform: rotate(90deg);
  }

  /* ── Detail panel ── */

  .arh-detail {
    padding: 0 14px 14px;
  }

  .arh-detail-divider {
    height: 1px;
    background: rgba(255, 255, 255, 0.05);
    margin-bottom: 12px;
  }

  .arh-detail-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
    gap: 8px;
    margin: 0;
  }

  .arh-detail-item {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .arh-detail-item dt {
    font-size: 0.5625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .arh-detail-item dd {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
    margin: 0;
  }

  .arh-detail-cost {
    color: rgba(34, 197, 94, 0.8) !important;
    font-weight: 500;
  }

  .arh-mono {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    word-break: break-all;
  }
</style>
