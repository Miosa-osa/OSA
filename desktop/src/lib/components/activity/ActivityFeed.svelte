<script lang="ts">
  import { slide } from 'svelte/transition';
  import { activityStore } from '$lib/stores/activity.svelte';
  import type { Activity } from '$lib/stores/activity.svelte';

  // SVG icon paths keyed by icon name
  const ICON_PATHS: Record<string, string> = {
    terminal: '<polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/>',
    file: '<path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><polyline points="14 2 14 8 20 8"/>',
    edit: '<path d="M17 3a2.83 2.83 0 114 4L7.5 20.5 2 22l1.5-5.5z"/>',
    'file-plus': '<path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="12" y1="18" x2="12" y2="12"/><line x1="9" y1="15" x2="15" y2="15"/>',
    trash: '<polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/>',
    folder: '<path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z"/>',
    search: '<circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>',
    globe: '<circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 014 10 15.3 15.3 0 01-4 10 15.3 15.3 0 01-4-10 15.3 15.3 0 014-10z"/>',
    monitor: '<rect x="2" y="3" width="20" height="14" rx="2" ry="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>',
    camera: '<path d="M23 19a2 2 0 01-2 2H3a2 2 0 01-2-2V8a2 2 0 012-2h4l2-3h6l2 3h4a2 2 0 012 2z"/><circle cx="12" cy="13" r="4"/>',
    cpu: '<rect x="4" y="4" width="16" height="16" rx="2" ry="2"/><rect x="9" y="9" width="6" height="6"/><line x1="9" y1="1" x2="9" y2="4"/><line x1="15" y1="1" x2="15" y2="4"/><line x1="9" y1="20" x2="9" y2="23"/><line x1="15" y1="20" x2="15" y2="23"/><line x1="20" y1="9" x2="23" y2="9"/><line x1="20" y1="14" x2="23" y2="14"/><line x1="1" y1="9" x2="4" y2="9"/><line x1="1" y1="14" x2="4" y2="14"/>',
    list: '<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>',
    tool: '<path d="M14.7 6.3a1 1 0 000 1.4l1.6 1.6a1 1 0 001.4 0l3.77-3.77a6 6 0 01-7.94 7.94l-6.91 6.91a2.12 2.12 0 01-3-3l6.91-6.91a6 6 0 017.94-7.94l-3.76 3.76z"/>',
  };

  // ── Elapsed time formatting ──────────────────────────────────────────────────

  function formatMs(ms: number): string {
    if (ms < 1000) return `${ms}ms`;
    if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
    const m = Math.floor(ms / 60_000);
    const s = Math.floor((ms % 60_000) / 1000);
    return `${m}m ${s}s`;
  }

  function elapsedMs(activity: Activity): number {
    return (activity.finishedAt ?? Date.now()) - activity.startedAt;
  }

  // Tick every 250ms so elapsed times update during active calls
  let tick = $state(0);
  $effect(() => {
    const id = setInterval(() => { tick++; }, 250);
    return () => clearInterval(id);
  });

  // Reactive elapsed — reads tick to stay live
  function liveElapsed(a: Activity): string {
    void tick; // subscribe to tick
    return formatMs(elapsedMs(a));
  }

  // Total session elapsed
  const totalLabel = $derived(() => {
    void tick;
    return formatMs(activityStore.totalElapsedMs);
  });

  // Verbosity label
  const verbosityLabel: Record<string, string> = {
    off:     'Off',
    new:     'New',
    all:     'All',
    verbose: 'Verbose',
  };

  // ── Keyboard handler ─────────────────────────────────────────────────────────

  function onBarKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      activityStore.toggleExpanded();
    }
  }
</script>

{#if activityStore.activities.length > 0 && activityStore.verbosity !== 'off'}
  <div class="feed-wrap" role="region" aria-label="Activity feed">
    <!-- Collapsed bar — always visible when there are activities -->
    <div
      class="feed-bar"
      class:feed-bar--expanded={activityStore.isExpanded}
      onclick={activityStore.toggleExpanded.bind(activityStore)}
      onkeydown={onBarKeydown}
      role="button"
      tabindex="0"
      aria-expanded={activityStore.isExpanded}
      aria-controls="feed-list"
    >
      <!-- Current activity indicator -->
      {#if activityStore.currentActivity}
        {@const cur = activityStore.currentActivity}
        <span class="feed-icon" aria-hidden="true"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{@html ICON_PATHS[cur.icon] ?? ICON_PATHS['tool']}</svg></span>
        <span class="feed-current-label">
          {cur.label || cur.tool}
        </span>
        <span
          class="feed-duration"
          class:feed-duration--running={cur.finishedAt === null}
          class:feed-duration--error={cur.isError}
        >
          {liveElapsed(cur)}
        </span>
      {:else}
        <span class="feed-current-label feed-idle">Idle</span>
      {/if}

      <div class="feed-bar-right">
        <!-- Activity count -->
        {#if activityStore.activities.length > 1}
          <span class="feed-count" aria-label="{activityStore.activities.length} tool calls">
            {activityStore.activities.length} calls
          </span>
        {/if}

        <!-- Total elapsed -->
        {#if activityStore.totalElapsedMs > 0}
          <span class="feed-total">
            {totalLabel()}
          </span>
        {/if}

        <!-- Verbosity toggle -->
        <button
          class="feed-verbosity"
          onclick={(e) => { e.stopPropagation(); activityStore.cycleVerbosity(); }}
          aria-label="Verbosity: {verbosityLabel[activityStore.verbosity]}. Click to cycle."
          title="Cycle verbosity"
        >
          {verbosityLabel[activityStore.verbosity]}
        </button>

        <!-- Chevron -->
        <span class="feed-chevron" class:rotated={activityStore.isExpanded} aria-hidden="true">›</span>
      </div>
    </div>

    <!-- Expanded list -->
    {#if activityStore.isExpanded}
      <div
        id="feed-list"
        class="feed-list"
        transition:slide={{ duration: 200 }}
        role="list"
        aria-label="Tool call history"
      >
        {#each activityStore.visibleActivities as activity (activity.id)}
          <div
            class="feed-item"
            class:feed-item--running={activity.finishedAt === null}
            class:feed-item--error={activity.isError}
            role="listitem"
          >
            <span class="feed-item-icon" aria-hidden="true"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{@html ICON_PATHS[activity.icon] ?? ICON_PATHS['tool']}</svg></span>
            <span class="feed-item-label">{activity.label || activity.tool}</span>
            {#if activityStore.verbosity === 'verbose' && activity.summary}
              <span class="feed-item-summary">{activity.summary}</span>
            {/if}
            <span class="feed-item-duration" class:feed-item-duration--running={activity.finishedAt === null}>
              {liveElapsed(activity)}
            </span>
            {#if activity.isError}
              <span class="feed-item-error-dot" aria-label="Error" title="Tool returned error">!</span>
            {:else if activity.finishedAt !== null}
              <span class="feed-item-done-dot" aria-hidden="true"><svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg></span>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>
{/if}

<style>
  /* ── Wrapper ── */

  .feed-wrap {
    width: 100%;
    overflow: hidden;
  }

  /* ── Collapsed bar ── */

  .feed-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 7px 12px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-md);
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    font-size: 0.8125rem;
    user-select: none;
  }

  .feed-bar:hover {
    background: rgba(255, 255, 255, 0.06);
    border-color: rgba(255, 255, 255, 0.1);
  }

  .feed-bar--expanded {
    border-radius: 0 0 var(--radius-md) var(--radius-md);
    border-top-color: transparent;
    background: rgba(255, 255, 255, 0.05);
  }

  .feed-icon {
    flex-shrink: 0;
    color: rgba(255, 255, 255, 0.5);
    display: flex;
    align-items: center;
  }

  .feed-current-label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.8125rem;
  }

  .feed-idle {
    color: rgba(255, 255, 255, 0.3);
    font-style: italic;
  }

  .feed-duration {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.35);
    flex-shrink: 0;
  }

  .feed-duration--running {
    color: rgba(255, 255, 255, 0.55);
    animation: pulse-opacity 1.5s ease-in-out infinite;
  }

  .feed-duration--error {
    color: rgba(239, 68, 68, 0.7);
  }

  @keyframes pulse-opacity {
    0%, 100% { opacity: 0.5; }
    50%       { opacity: 1; }
  }

  .feed-bar-right {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }

  .feed-count {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.25);
    font-family: var(--font-mono);
  }

  .feed-total {
    font-size: 0.6875rem;
    font-family: var(--font-mono);
    color: rgba(255, 255, 255, 0.3);
  }

  /* Verbosity toggle */
  .feed-verbosity {
    font-size: 0.625rem;
    font-weight: 500;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    padding: 2px 7px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.4);
    cursor: pointer;
    transition: background 0.12s, color 0.12s;
  }

  .feed-verbosity:hover {
    background: rgba(255, 255, 255, 0.12);
    color: rgba(255, 255, 255, 0.7);
  }

  .feed-chevron {
    font-size: 0.9375rem;
    color: rgba(255, 255, 255, 0.25);
    transition: transform 0.18s ease;
    display: inline-block;
  }

  .feed-chevron.rotated {
    transform: rotate(90deg);
  }

  /* ── Expanded list ── */

  .feed-list {
    background: rgba(0, 0, 0, 0.25);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-bottom-left-radius: var(--radius-md);
    border-bottom-right-radius: var(--radius-md);
    border-top: none;
    max-height: 260px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .feed-item {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    font-size: 0.8125rem;
    transition: background 0.1s;
  }

  .feed-item:last-child {
    border-bottom: none;
  }

  .feed-item:hover {
    background: rgba(255, 255, 255, 0.03);
  }

  .feed-item--running {
    background: rgba(255, 255, 255, 0.02);
  }

  .feed-item--error {
    background: rgba(239, 68, 68, 0.04);
  }

  .feed-item-icon {
    flex-shrink: 0;
    color: rgba(255, 255, 255, 0.45);
    display: flex;
    align-items: center;
  }

  .feed-item-label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: rgba(255, 255, 255, 0.65);
  }

  .feed-item-summary {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.3);
    max-width: 200px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex-shrink: 0;
  }

  .feed-item-duration {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.25);
    flex-shrink: 0;
  }

  .feed-item-duration--running {
    color: rgba(255, 255, 255, 0.5);
    animation: pulse-opacity 1.5s ease-in-out infinite;
  }

  .feed-item-done-dot {
    font-size: 0.6875rem;
    color: rgba(34, 197, 94, 0.5);
    flex-shrink: 0;
  }

  .feed-item-error-dot {
    font-size: 0.75rem;
    font-weight: 700;
    color: rgba(239, 68, 68, 0.7);
    flex-shrink: 0;
  }
</style>
