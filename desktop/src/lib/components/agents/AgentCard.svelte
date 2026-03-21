<!-- src/lib/components/agents/AgentCard.svelte -->
<!-- Single agent card: status, identity, actions, metrics, expand/collapse log. -->
<script lang="ts">
  import { slide } from 'svelte/transition';
  import type { Agent } from '$lib/api/types';

  interface Props {
    agent: Agent;
    isExpanded?: boolean;
    isPending?: boolean;
    onToggleExpand?: (id: string) => void;
    onPause?: (agent: Agent) => void;
    onCancel?: (agent: Agent) => void;
  }

  let {
    agent,
    isExpanded = false,
    isPending = false,
    onToggleExpand,
    onPause,
    onCancel,
  }: Props = $props();

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function formatDuration(seconds: number | undefined): string {
    if (seconds === undefined) return '—';
    if (seconds < 60) return `${Math.round(seconds)}s`;
    const m = Math.floor(seconds / 60);
    const s = Math.round(seconds % 60);
    return `${m}m ${s}s`;
  }

  function formatTokens(tokens: number | undefined): string {
    if (tokens === undefined) return '—';
    if (tokens >= 1000) return `${(tokens / 1000).toFixed(1)}k`;
    return String(tokens);
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

  function statusLabel(status: Agent['status']): string {
    switch (status) {
      case 'running': return 'Running';
      case 'queued':  return 'Queued';
      case 'done':    return 'Done';
      case 'error':   return 'Failed';
      case 'idle':    return 'Idle';
    }
  }

  const isActive = $derived(agent.status === 'running' || agent.status === 'queued');
</script>

<article
  class="ac-card"
  class:ac-card--running={agent.status === 'running'}
  class:ac-card--queued={agent.status === 'queued'}
  class:ac-card--done={agent.status === 'done'}
  class:ac-card--error={agent.status === 'error'}
  role="listitem"
>
  <!-- ── Card header ── -->
  <div class="ac-header">
    <div class="ac-header-left">
      <div class="ac-status-indicator" aria-hidden="true">
        <span
          class="ac-status-dot"
          class:ac-status-dot--running={agent.status === 'running'}
          class:ac-status-dot--queued={agent.status === 'queued'}
          class:ac-status-dot--done={agent.status === 'done'}
          class:ac-status-dot--error={agent.status === 'error'}
          class:ac-status-dot--idle={agent.status === 'idle'}
        ></span>
      </div>
      <div class="ac-identity">
        <h2 class="ac-name">{agent.name}</h2>
        <span
          class="ac-status-badge"
          class:ac-status-badge--running={agent.status === 'running'}
          class:ac-status-badge--queued={agent.status === 'queued'}
          class:ac-status-badge--done={agent.status === 'done'}
          class:ac-status-badge--error={agent.status === 'error'}
        >
          {statusLabel(agent.status)}
        </span>
      </div>
    </div>

    <!-- Actions -->
    <div class="ac-actions">
      {#if isActive}
        <button
          class="ac-action-btn ac-action-btn--pause"
          onclick={() => onPause?.(agent)}
          disabled={isPending}
          aria-label="Pause agent {agent.name}"
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
            <rect x="2" y="1.5" width="3" height="9" rx="1"/>
            <rect x="7" y="1.5" width="3" height="9" rx="1"/>
          </svg>
        </button>
        <button
          class="ac-action-btn ac-action-btn--cancel"
          onclick={() => onCancel?.(agent)}
          disabled={isPending}
          aria-label="Cancel agent {agent.name}"
        >
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
            <line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/>
            <line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/>
          </svg>
        </button>
      {/if}

      <button
        class="ac-action-btn ac-action-btn--expand"
        onclick={() => onToggleExpand?.(agent.id)}
        aria-expanded={isExpanded}
        aria-controls="ac-log-{agent.id}"
        aria-label="{isExpanded ? 'Collapse' : 'Expand'} details for {agent.name}"
      >
        <span
          class="ac-chevron"
          class:ac-chevron--open={isExpanded}
          aria-hidden="true"
        >›</span>
      </button>
    </div>
  </div>

  <!-- ── Current action ── -->
  {#if agent.task && isActive}
    <p class="ac-current-action" title={agent.task}>
      <span class="ac-action-prefix" aria-hidden="true">›</span>
      {agent.task}
    </p>
  {/if}

  <!-- ── Progress bar ── -->
  {#if isActive && agent.progress > 0}
    <div
      class="ac-progress-track"
      role="progressbar"
      aria-valuenow={agent.progress}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label="Agent progress"
    >
      <div class="ac-progress-fill" style="width: {agent.progress}%"></div>
    </div>
  {/if}

  <!-- ── Metrics row ── -->
  <div class="ac-metrics" aria-label="Agent metrics">
    <div class="ac-metric">
      <span class="ac-metric-label">Duration</span>
      <span class="ac-metric-value">{formatDuration(agent.duration)}</span>
    </div>
    <div class="ac-metric">
      <span class="ac-metric-label">Tokens</span>
      <span class="ac-metric-value">{formatTokens(agent.tokens)}</span>
    </div>
    <div class="ac-metric">
      <span class="ac-metric-label">Started</span>
      <span class="ac-metric-value">{formatRelative(agent.created_at)}</span>
    </div>
  </div>

  <!-- ── Expanded log ── -->
  {#if isExpanded}
    <div
      id="ac-log-{agent.id}"
      class="ac-log"
      transition:slide={{ duration: 180 }}
    >
      <div class="ac-log-divider" aria-hidden="true"></div>

      {#if agent.error}
        <div class="ac-log-section" role="alert">
          <p class="ac-log-label">Error</p>
          <pre class="ac-log-text ac-log-text--error">{agent.error}</pre>
        </div>
      {/if}

      {#if agent.task}
        <div class="ac-log-section">
          <p class="ac-log-label">Task</p>
          <p class="ac-log-text">{agent.task}</p>
        </div>
      {/if}

      <div class="ac-log-section">
        <p class="ac-log-label">Agent ID</p>
        <code class="ac-log-id">{agent.id}</code>
      </div>

      <div class="ac-log-section">
        <p class="ac-log-label">Last updated</p>
        <span class="ac-log-text">{formatRelative(agent.updated_at)}</span>
      </div>
    </div>
  {/if}
</article>

<style>
  /* ── Card ── */

  .ac-card {
    background: rgba(255, 255, 255, 0.04);
    backdrop-filter: blur(24px);
    -webkit-backdrop-filter: blur(24px);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    transition:
      border-color 0.2s ease,
      box-shadow 0.2s ease;
  }

  .ac-card--running {
    border-color: rgba(34, 197, 94, 0.2);
    box-shadow:
      0 0 0 1px rgba(34, 197, 94, 0.06),
      inset 0 1px 0 rgba(34, 197, 94, 0.06);
  }

  .ac-card--queued {
    border-color: rgba(59, 130, 246, 0.2);
    box-shadow: 0 0 0 1px rgba(59, 130, 246, 0.06);
  }

  .ac-card--error {
    border-color: rgba(239, 68, 68, 0.2);
    box-shadow: 0 0 0 1px rgba(239, 68, 68, 0.06);
  }

  .ac-card--done {
    opacity: 0.75;
  }

  /* ── Header ── */

  .ac-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 8px;
  }

  .ac-header-left {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
    flex: 1;
  }

  /* ── Status dot ── */

  .ac-status-indicator {
    flex-shrink: 0;
  }

  .ac-status-dot {
    display: block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.2);
  }

  .ac-status-dot--running {
    background: var(--accent-success);
    box-shadow: 0 0 6px rgba(34, 197, 94, 0.5);
    animation: ac-pulse-glow 2s ease-in-out infinite;
  }

  .ac-status-dot--queued {
    background: var(--accent-primary);
    box-shadow: 0 0 6px rgba(59, 130, 246, 0.4);
    animation: ac-pulse-glow-blue 2s ease-in-out infinite;
  }

  .ac-status-dot--done {
    background: rgba(255, 255, 255, 0.25);
  }

  .ac-status-dot--error {
    background: var(--accent-error);
    box-shadow: 0 0 6px rgba(239, 68, 68, 0.4);
  }

  .ac-status-dot--idle {
    background: rgba(255, 255, 255, 0.18);
  }

  @keyframes ac-pulse-glow {
    0%, 100% { box-shadow: 0 0 4px rgba(34, 197, 94, 0.4); }
    50%       { box-shadow: 0 0 10px rgba(34, 197, 94, 0.7); }
  }

  @keyframes ac-pulse-glow-blue {
    0%, 100% { box-shadow: 0 0 4px rgba(59, 130, 246, 0.3); }
    50%       { box-shadow: 0 0 10px rgba(59, 130, 246, 0.6); }
  }

  /* ── Identity ── */

  .ac-identity {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }

  .ac-name {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-primary);
    line-height: 1.2;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .ac-status-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 7px;
    border-radius: var(--radius-full);
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    width: fit-content;
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.06);
  }

  .ac-status-badge--running {
    background: rgba(34, 197, 94, 0.12);
    color: rgba(34, 197, 94, 0.9);
    border-color: rgba(34, 197, 94, 0.2);
  }

  .ac-status-badge--queued {
    background: rgba(59, 130, 246, 0.12);
    color: rgba(59, 130, 246, 0.9);
    border-color: rgba(59, 130, 246, 0.2);
  }

  .ac-status-badge--done {
    background: rgba(255, 255, 255, 0.06);
    color: rgba(255, 255, 255, 0.4);
    border-color: rgba(255, 255, 255, 0.06);
  }

  .ac-status-badge--error {
    background: rgba(239, 68, 68, 0.12);
    color: rgba(239, 68, 68, 0.9);
    border-color: rgba(239, 68, 68, 0.2);
  }

  /* ── Actions ── */

  .ac-actions {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
  }

  .ac-action-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border-radius: var(--radius-sm);
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.4);
    transition: all 0.15s;
    cursor: pointer;
  }

  .ac-action-btn:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.06);
    color: rgba(255, 255, 255, 0.7);
    border-color: rgba(255, 255, 255, 0.15);
  }

  .ac-action-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .ac-action-btn--cancel:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.1);
    color: rgba(239, 68, 68, 0.8);
    border-color: rgba(239, 68, 68, 0.2);
  }

  .ac-action-btn--expand {
    border-color: transparent;
  }

  .ac-chevron {
    font-size: 1rem;
    color: rgba(255, 255, 255, 0.3);
    transition: transform 0.18s ease;
    display: inline-block;
    line-height: 1;
  }

  .ac-chevron--open {
    transform: rotate(90deg);
  }

  /* ── Current action ── */

  .ac-current-action {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.4;
    padding: 0 2px;
    display: flex;
    align-items: baseline;
    gap: 6px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .ac-action-prefix {
    color: var(--accent-success);
    font-weight: 600;
    flex-shrink: 0;
    opacity: 0.7;
  }

  /* ── Progress bar ── */

  .ac-progress-track {
    height: 2px;
    background: rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    overflow: hidden;
  }

  .ac-progress-fill {
    height: 100%;
    background: linear-gradient(90deg, rgba(34, 197, 94, 0.6), rgba(34, 197, 94, 0.9));
    border-radius: var(--radius-full);
    transition: width 0.4s ease;
  }

  .ac-card--queued .ac-progress-fill {
    background: linear-gradient(90deg, rgba(59, 130, 246, 0.6), rgba(59, 130, 246, 0.9));
  }

  /* ── Metrics ── */

  .ac-metrics {
    display: flex;
    gap: 0;
    background: rgba(255, 255, 255, 0.025);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-md);
    overflow: hidden;
  }

  .ac-metric {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 8px 10px;
    border-right: 1px solid rgba(255, 255, 255, 0.05);
  }

  .ac-metric:last-child {
    border-right: none;
  }

  .ac-metric-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .ac-metric-value {
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  /* ── Expanded log ── */

  .ac-log {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .ac-log-divider {
    height: 1px;
    background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.06), transparent);
    margin-bottom: 0;
  }

  .ac-log-section {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .ac-log-label {
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.2);
  }

  .ac-log-text {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.5;
  }

  .ac-log-text--error {
    color: rgba(239, 68, 68, 0.8);
    font-family: var(--font-mono);
    font-size: 0.75rem;
    background: rgba(239, 68, 68, 0.05);
    border: 1px solid rgba(239, 68, 68, 0.1);
    border-radius: var(--radius-sm);
    padding: 8px 10px;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 120px;
    overflow-y: auto;
    margin: 0;
  }

  .ac-log-id {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.03);
    padding: 3px 7px;
    border-radius: var(--radius-xs);
    border: 1px solid rgba(255, 255, 255, 0.05);
    user-select: text;
  }
</style>
