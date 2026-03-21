<!-- src/lib/components/agents/AgentOverview.svelte -->
<!-- Overview tab: status card, metrics grid, current task, agent identity info. -->
<script lang="ts">
  import type { Agent } from '$lib/api/types';

  interface Props {
    agent: Agent;
  }

  let { agent }: Props = $props();

  function formatDuration(seconds: number | undefined): string {
    if (seconds === undefined) return '—';
    if (seconds < 60) return `${Math.round(seconds)}s`;
    const m = Math.floor(seconds / 60);
    const s = Math.round(seconds % 60);
    return `${m}m ${s}s`;
  }

  function formatTokens(tokens: number | undefined): string {
    if (tokens === undefined) return '—';
    if (tokens >= 1_000_000) return `${(tokens / 1_000_000).toFixed(2)}M`;
    if (tokens >= 1000) return `${(tokens / 1000).toFixed(1)}k`;
    return String(tokens);
  }

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleString(undefined, {
      dateStyle: 'medium',
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

  const isActive = $derived(agent.status === 'running' || agent.status === 'queued');
</script>

<div class="aov-root">

  <!-- ── Status card ── -->
  <section class="aov-card" aria-label="Agent status">
    <h2 class="aov-section-title">Status</h2>
    <div class="aov-status-grid">
      <div class="aov-stat-cell">
        <span class="aov-stat-label">Current Status</span>
        <div class="aov-status-value">
          <span
            class="aov-status-dot"
            class:aov-status-dot--running={agent.status === 'running'}
            class:aov-status-dot--queued={agent.status === 'queued'}
            class:aov-status-dot--done={agent.status === 'done'}
            class:aov-status-dot--error={agent.status === 'error'}
            aria-hidden="true"
          ></span>
          <span class="aov-stat-value">{agent.status}</span>
        </div>
      </div>
      <div class="aov-stat-cell">
        <span class="aov-stat-label">Progress</span>
        <span class="aov-stat-value">{agent.progress}%</span>
      </div>
      <div class="aov-stat-cell">
        <span class="aov-stat-label">Created</span>
        <span class="aov-stat-value">{formatRelative(agent.created_at)}</span>
      </div>
      <div class="aov-stat-cell">
        <span class="aov-stat-label">Last Active</span>
        <span class="aov-stat-value">{formatRelative(agent.updated_at)}</span>
      </div>
    </div>

    {#if isActive && agent.progress > 0}
      <div class="aov-progress-track" role="progressbar" aria-valuenow={agent.progress} aria-valuemin={0} aria-valuemax={100} aria-label="Agent progress">
        <div
          class="aov-progress-fill"
          class:aov-progress-fill--queued={agent.status === 'queued'}
          style="width: {agent.progress}%"
        ></div>
      </div>
    {/if}
  </section>

  <!-- ── Metrics grid ── -->
  <section class="aov-card" aria-label="Agent metrics">
    <h2 class="aov-section-title">Metrics</h2>
    <div class="aov-metrics-grid">
      <div class="aov-metric-cell">
        <span class="aov-metric-label">Duration</span>
        <span class="aov-metric-value">{formatDuration(agent.duration)}</span>
      </div>
      <div class="aov-metric-cell">
        <span class="aov-metric-label">Tokens Used</span>
        <span class="aov-metric-value">{formatTokens(agent.tokens)}</span>
      </div>
      <div class="aov-metric-cell">
        <span class="aov-metric-label">Agent ID</span>
        <code class="aov-id-value">{agent.id}</code>
      </div>
      <div class="aov-metric-cell">
        <span class="aov-metric-label">Created At</span>
        <span class="aov-metric-value">{formatDate(agent.created_at)}</span>
      </div>
    </div>
  </section>

  <!-- ── Current task ── -->
  {#if agent.task}
    <section class="aov-card" aria-label="Current task">
      <h2 class="aov-section-title">
        {isActive ? 'Current Task' : 'Last Task'}
      </h2>
      <p class="aov-task-text">{agent.task}</p>
    </section>
  {/if}

  <!-- ── Error ── -->
  {#if agent.error}
    <section class="aov-card aov-card--error" role="alert" aria-label="Agent error">
      <h2 class="aov-section-title aov-section-title--error">Error</h2>
      <pre class="aov-error-text">{agent.error}</pre>
    </section>
  {/if}

  <!-- ── Timeline ── -->
  <section class="aov-card" aria-label="Agent timeline">
    <h2 class="aov-section-title">Timeline</h2>
    <div class="aov-timeline">
      <div class="aov-timeline-item">
        <span class="aov-tl-dot" aria-hidden="true"></span>
        <div class="aov-tl-content">
          <span class="aov-tl-label">Created</span>
          <span class="aov-tl-time">{formatDate(agent.created_at)}</span>
        </div>
      </div>
      <div class="aov-timeline-item">
        <span class="aov-tl-dot aov-tl-dot--updated" aria-hidden="true"></span>
        <div class="aov-tl-content">
          <span class="aov-tl-label">Last Updated</span>
          <span class="aov-tl-time">{formatDate(agent.updated_at)}</span>
        </div>
      </div>
    </div>
  </section>

</div>

<style>
  .aov-root {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  /* ── Card ── */

  .aov-card {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
    padding: 16px 18px;
  }

  .aov-card--error {
    border-color: rgba(239, 68, 68, 0.2);
    background: rgba(239, 68, 68, 0.04);
  }

  .aov-section-title {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--text-muted);
    margin-bottom: 12px;
  }

  .aov-section-title--error {
    color: rgba(239, 68, 68, 0.6);
  }

  /* ── Status grid ── */

  .aov-status-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
    gap: 1px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-md);
    overflow: hidden;
    margin-bottom: 12px;
  }

  .aov-stat-cell {
    display: flex;
    flex-direction: column;
    gap: 3px;
    padding: 10px 12px;
    background: var(--bg-secondary);
  }

  .aov-stat-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .aov-stat-value {
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-secondary);
    text-transform: capitalize;
    font-variant-numeric: tabular-nums;
  }

  .aov-status-value {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .aov-status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.2);
    flex-shrink: 0;
  }

  .aov-status-dot--running {
    background: var(--accent-success);
    animation: aov-pulse 2s ease-in-out infinite;
  }

  .aov-status-dot--queued  { background: var(--accent-primary); }
  .aov-status-dot--done    { background: rgba(255, 255, 255, 0.25); }
  .aov-status-dot--error   { background: var(--accent-error); }

  @keyframes aov-pulse {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0.5; }
  }

  /* ── Progress ── */

  .aov-progress-track {
    height: 3px;
    background: rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    overflow: hidden;
  }

  .aov-progress-fill {
    height: 100%;
    background: linear-gradient(90deg, rgba(34, 197, 94, 0.6), rgba(34, 197, 94, 0.9));
    border-radius: var(--radius-full);
    transition: width 0.5s ease;
  }

  .aov-progress-fill--queued {
    background: linear-gradient(90deg, rgba(59, 130, 246, 0.6), rgba(59, 130, 246, 0.9));
  }

  /* ── Metrics grid ── */

  .aov-metrics-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 12px;
  }

  .aov-metric-cell {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .aov-metric-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .aov-metric-value {
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .aov-id-value {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.03);
    padding: 2px 6px;
    border-radius: var(--radius-xs);
    border: 1px solid rgba(255, 255, 255, 0.05);
    word-break: break-all;
    user-select: text;
    width: fit-content;
  }

  /* ── Task ── */

  .aov-task-text {
    font-size: 0.875rem;
    color: var(--text-secondary);
    line-height: 1.6;
  }

  /* ── Error ── */

  .aov-error-text {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: rgba(239, 68, 68, 0.8);
    background: rgba(239, 68, 68, 0.05);
    border: 1px solid rgba(239, 68, 68, 0.1);
    border-radius: var(--radius-sm);
    padding: 10px 12px;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 160px;
    overflow-y: auto;
    margin: 0;
  }

  /* ── Timeline ── */

  .aov-timeline {
    display: flex;
    flex-direction: column;
    gap: 0;
    position: relative;
    padding-left: 20px;
  }

  .aov-timeline::before {
    content: '';
    position: absolute;
    left: 5px;
    top: 8px;
    bottom: 8px;
    width: 1px;
    background: rgba(255, 255, 255, 0.07);
  }

  .aov-timeline-item {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    position: relative;
    padding: 6px 0;
  }

  .aov-tl-dot {
    position: absolute;
    left: -17px;
    top: 10px;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.15);
    border: 1px solid rgba(255, 255, 255, 0.2);
    flex-shrink: 0;
  }

  .aov-tl-dot--updated {
    background: rgba(59, 130, 246, 0.3);
    border-color: rgba(59, 130, 246, 0.4);
  }

  .aov-tl-content {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .aov-tl-label {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .aov-tl-time {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
  }
</style>
