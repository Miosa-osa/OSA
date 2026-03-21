<script lang="ts">
  import type { DashboardAgent } from "$api/types";

  interface Props {
    agents: DashboardAgent[];
    agentsTotal: number;
  }

  let { agents, agentsTotal }: Props = $props();

  function statusColor(status: string): string {
    if (status === "running") return "aap-running";
    if (status === "paused") return "aap-paused";
    return "aap-idle";
  }

  function relativeTime(ts?: string): string {
    if (!ts) return "";
    const diff = Math.floor((Date.now() - new Date(ts).getTime()) / 1000);
    if (diff < 60) return `${diff}s ago`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    return `${Math.floor(diff / 3600)}h ago`;
  }
</script>

<section class="aap" aria-label="Active agents">
  <header class="aap-header">
    <h3 class="aap-title">Active Agents</h3>
    <span class="aap-count">{agents.length}/{agentsTotal}</span>
  </header>

  {#if agents.length === 0}
    <p class="aap-empty">No agents running — agents activate when you give them tasks</p>
  {:else}
    <ul class="aap-list">
      {#each agents as agent (agent.name)}
        <li class="aap-item">
          <span class="aap-dot {statusColor(agent.status)}"></span>
          <div class="aap-info">
            <span class="aap-name">{agent.name}</span>
            {#if agent.current_task}
              <span class="aap-task">{agent.current_task}</span>
            {/if}
          </div>
          {#if agent.last_active}
            <span class="aap-time">{relativeTime(agent.last_active)}</span>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</section>

<style>
  .aap {
    background: var(--bg-surface);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    min-height: 200px;
  }

  .aap-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .aap-title {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
    margin: 0;
  }

  .aap-count {
    font-size: 12px;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
  }

  .aap-empty {
    font-size: 13px;
    color: var(--text-tertiary);
    text-align: center;
    padding: 24px 0;
    margin: 0;
  }

  .aap-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 8px;
    overflow-y: auto;
    max-height: 320px;
  }

  .aap-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 10px;
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid transparent;
    transition: border-color 0.15s ease;
  }

  .aap-item:hover {
    border-color: var(--border-default);
  }

  .aap-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .aap-running {
    background: var(--accent-success);
    box-shadow: 0 0 6px rgba(34, 197, 94, 0.4);
  }

  .aap-idle { background: var(--accent-warning); }
  .aap-paused { background: var(--accent-error); }

  .aap-info {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .aap-name {
    font-size: 13px;
    font-weight: 500;
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .aap-task {
    font-size: 11px;
    color: var(--text-tertiary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .aap-time {
    font-size: 11px;
    color: var(--text-tertiary);
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
</style>
