<script lang="ts">
  import type { DashboardActivity } from "$api/types";

  interface Props {
    activities: DashboardActivity[];
  }

  let { activities }: Props = $props();

  function relativeTime(ts: string): string {
    const diff = Math.floor((Date.now() - new Date(ts).getTime()) / 1000);
    if (diff < 60) return `${diff}s ago`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
    return `${Math.floor(diff / 86400)}d ago`;
  }

  function levelClass(level: string): string {
    if (level === "error") return "raf-error";
    if (level === "warning") return "raf-warn";
    return "raf-info";
  }

  function typeIcon(type: string): string {
    const map: Record<string, string> = {
      signal_classified: "M13 2L3 14h9l-1 8 10-12h-9l1-8",
      task_completed: "M9 11l3 3L22 4",
      task_failed: "M18 6L6 18 M6 6l12 12",
      agent_started: "M5 12h14 M12 5l7 7-7 7",
      agent_paused: "M6 4h4v16H6z M14 4h4v16h-4z",
      error: "M12 9v4 M12 17h.01 M10.29 3.86l-8.6 14.86a2 2 0 0 0 1.71 3h17.2a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z",
    };
    return map[type] ?? "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20";
  }
</script>

<section class="raf" aria-label="Recent activity">
  <header class="raf-header">
    <h3 class="raf-title">Recent Activity</h3>
    <a href="/app/activity" class="raf-link">View all</a>
  </header>

  {#if activities.length === 0}
    <p class="raf-empty">No activity yet — start a chat to see events here</p>
  {:else}
    <ul class="raf-list">
      {#each activities as event, i (i)}
        <li class="raf-item {levelClass(event.level)}">
          <div class="raf-icon" aria-hidden="true">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d={typeIcon(event.type)} />
            </svg>
          </div>
          <div class="raf-body">
            <span class="raf-msg">{event.message || event.type}</span>
            <div class="raf-meta">
              {#if event.agent}
                <span class="raf-agent">{event.agent}</span>
              {/if}
              <span class="raf-time">{relativeTime(event.timestamp)}</span>
            </div>
          </div>
        </li>
      {/each}
    </ul>
  {/if}
</section>

<style>
  .raf {
    background: var(--bg-surface);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    min-height: 200px;
  }

  .raf-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .raf-title {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
    margin: 0;
  }

  .raf-link {
    font-size: 12px;
    color: var(--accent-primary);
    text-decoration: none;
  }

  .raf-link:hover {
    text-decoration: underline;
  }

  .raf-empty {
    font-size: 13px;
    color: var(--text-tertiary);
    text-align: center;
    padding: 24px 0;
    margin: 0;
  }

  .raf-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
    overflow-y: auto;
    max-height: 400px;
  }

  .raf-item {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 8px 10px;
    border-radius: var(--radius-sm);
    transition: background 0.15s ease;
  }

  .raf-item:hover {
    background: rgba(255, 255, 255, 0.03);
  }

  .raf-icon {
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius-sm);
    flex-shrink: 0;
    margin-top: 1px;
  }

  .raf-info .raf-icon { color: var(--accent-primary); background: rgba(59, 130, 246, 0.1); }
  .raf-warn .raf-icon { color: var(--accent-warning); background: rgba(245, 158, 11, 0.1); }
  .raf-error .raf-icon { color: var(--accent-error); background: rgba(239, 68, 68, 0.1); }

  .raf-body {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .raf-msg {
    font-size: 13px;
    color: var(--text-primary);
    line-height: 1.4;
  }

  .raf-meta {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 11px;
  }

  .raf-agent {
    color: var(--accent-primary);
    font-weight: 500;
  }

  .raf-time {
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
  }
</style>
