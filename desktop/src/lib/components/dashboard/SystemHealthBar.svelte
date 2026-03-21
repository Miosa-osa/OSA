<script lang="ts">
  import type { DashboardSystemHealth } from "$api/types";

  interface Props {
    health: DashboardSystemHealth;
    uptimeSeconds: number;
    offline?: boolean;
  }

  let { health, uptimeSeconds, offline = false }: Props = $props();

  const uptime = $derived(formatUptime(uptimeSeconds));

  function formatUptime(s: number): string {
    if (s < 60) return `${s}s`;
    if (s < 3600) return `${Math.floor(s / 60)}m`;
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    return m > 0 ? `${h}h ${m}m` : `${h}h`;
  }

  function statusClass(status: string): string {
    if (status === "ok" || status === "connected") return "shb-ok";
    if (status === "degraded") return "shb-warn";
    return "shb-error";
  }
</script>

<div class="shb {offline ? 'shb-degraded' : ''}" role="status" aria-label="System health">
  {#if offline}
    <div class="shb-item">
      <span class="shb-dot shb-error shb-pulse"></span>
      <span class="shb-label">Backend</span>
      <span class="shb-val shb-val-error">offline</span>
    </div>
  {:else}
    <div class="shb-item">
      <span class="shb-dot {statusClass(health.backend)}"></span>
      <span class="shb-label">Backend</span>
      <span class="shb-val">{health.backend}</span>
    </div>

    <span class="shb-sep" aria-hidden="true"></span>

    <div class="shb-item">
      <span class="shb-dot {statusClass(health.provider_status)}"></span>
      <span class="shb-label">Provider</span>
      <span class="shb-val">{health.provider ?? "none"}</span>
    </div>

    <span class="shb-sep" aria-hidden="true"></span>

    <div class="shb-item">
      <span class="shb-label">Uptime</span>
      <span class="shb-val">{uptime}</span>
    </div>

    <span class="shb-sep" aria-hidden="true"></span>

    <div class="shb-item">
      <span class="shb-label">Memory</span>
      <span class="shb-val">{health.memory_mb} MB</span>
    </div>
  {/if}
</div>

<style>
  .shb {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 8px 16px;
    background: var(--bg-surface);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    font-size: 12px;
    flex-wrap: wrap;
  }

  .shb-item {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .shb-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .shb-ok { background: var(--accent-success); }
  .shb-warn { background: var(--accent-warning); }
  .shb-error { background: var(--accent-error); }

  .shb-label {
    color: var(--text-tertiary);
    font-weight: 500;
  }

  .shb-val {
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .shb-sep {
    width: 1px;
    height: 14px;
    background: var(--border-default);
    flex-shrink: 0;
  }

  /* Offline / degraded variant */
  .shb-degraded {
    border-color: rgba(239, 68, 68, 0.2);
    background: rgba(239, 68, 68, 0.04);
  }

  .shb-val-error {
    color: var(--accent-error);
  }

  .shb-pulse {
    animation: shb-pulse 2s ease-in-out infinite;
  }

  @keyframes shb-pulse {
    0%, 100% { opacity: 1; transform: scale(1); }
    50%       { opacity: 0.35; transform: scale(0.7); }
  }
</style>
