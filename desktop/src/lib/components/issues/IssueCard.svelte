<script lang="ts">
  import type { Issue, IssueStatus } from '$lib/stores/issues.svelte';

  interface Props {
    issue: Issue;
    onSelect: (issue: Issue) => void;
    onStatusChange: (id: string, status: IssueStatus) => void;
  }

  let { issue, onSelect, onStatusChange }: Props = $props();

  let showStatusMenu = $state(false);

  function timeAgo(iso: string): string {
    const diff = Date.now() - new Date(iso).getTime();
    const mins = Math.floor(diff / 60_000);
    if (mins < 1) return 'just now';
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    const days = Math.floor(hrs / 24);
    if (days < 30) return `${days}d ago`;
    return `${Math.floor(days / 30)}mo ago`;
  }

  const STATUS_OPTIONS: IssueStatus[] = ['open', 'in_progress', 'done', 'blocked'];

  const STATUS_LABELS: Record<IssueStatus, string> = {
    open: 'Open',
    in_progress: 'In Progress',
    done: 'Done',
    blocked: 'Blocked',
  };

  function handleKeyDown(e: KeyboardEvent) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onSelect(issue);
    }
  }

  function handleStatusClick(e: MouseEvent) {
    e.stopPropagation();
    showStatusMenu = !showStatusMenu;
  }

  function handleStatusSelect(e: MouseEvent, status: IssueStatus) {
    e.stopPropagation();
    onStatusChange(issue.id, status);
    showStatusMenu = false;
  }

  function handleClickOutside() {
    showStatusMenu = false;
  }
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<div
  class="ic-row"
  role="button"
  tabindex="0"
  aria-label="Issue: {issue.title}"
  onclick={() => onSelect(issue)}
  onkeydown={handleKeyDown}
>
  <!-- Status dot (clickable) -->
  <div class="ic-status-wrap">
    <button
      class="ic-status-btn ic-status-btn--{issue.status}"
      onclick={handleStatusClick}
      aria-label="Change status: {STATUS_LABELS[issue.status]}"
      aria-haspopup="listbox"
      aria-expanded={showStatusMenu}
      title={STATUS_LABELS[issue.status]}
    >
      <span class="ic-dot ic-dot--{issue.status}" aria-hidden="true"></span>
    </button>

    {#if showStatusMenu}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        class="ic-status-menu"
        role="listbox"
        aria-label="Select status"
        onmouseleave={handleClickOutside}
      >
        {#each STATUS_OPTIONS as opt}
          <button
            class="ic-status-opt"
            class:ic-status-opt--active={issue.status === opt}
            role="option"
            aria-selected={issue.status === opt}
            onclick={(e) => handleStatusSelect(e, opt)}
          >
            <span class="ic-dot ic-dot--{opt}" aria-hidden="true"></span>
            {STATUS_LABELS[opt]}
          </button>
        {/each}
      </div>
    {/if}
  </div>

  <!-- Title -->
  <span class="ic-title">{issue.title}</span>

  <!-- Labels -->
  {#if issue.labels.length > 0}
    <div class="ic-labels" aria-label="Labels">
      {#each issue.labels.slice(0, 3) as label}
        <span class="ic-label">{label}</span>
      {/each}
    </div>
  {/if}

  <!-- Priority badge -->
  <span
    class="ic-priority ic-priority--{issue.priority}"
    aria-label="Priority: {issue.priority}"
  >
    {issue.priority}
  </span>

  <!-- Assignee -->
  {#if issue.assignee}
    <span class="ic-assignee" aria-label="Assigned to {issue.assignee}" title={issue.assignee}>
      {issue.assignee.slice(0, 2).toUpperCase()}
    </span>
  {:else}
    <span class="ic-assignee ic-assignee--empty" aria-hidden="true">--</span>
  {/if}

  <!-- Time ago -->
  <time
    class="ic-age"
    datetime={issue.created_at}
    title={new Date(issue.created_at).toLocaleString()}
  >
    {timeAgo(issue.created_at)}
  </time>
</div>

<style>
  .ic-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    cursor: pointer;
    transition: background 0.12s;
    position: relative;
    user-select: none;
  }

  .ic-row:hover {
    background: rgba(255, 255, 255, 0.03);
  }

  .ic-row:focus-visible {
    outline: 2px solid rgba(59, 130, 246, 0.5);
    outline-offset: -2px;
  }

  /* Status dot + dropdown */
  .ic-status-wrap {
    position: relative;
    flex-shrink: 0;
  }

  .ic-status-btn {
    width: 20px;
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    background: none;
    border: none;
    cursor: pointer;
    padding: 0;
    transition: background 0.12s;
  }

  .ic-status-btn:hover {
    background: rgba(255, 255, 255, 0.08);
  }

  .ic-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
    display: inline-block;
  }

  .ic-dot--open { background: var(--accent-success, #22c55e); }
  .ic-dot--in_progress { background: rgba(59, 130, 246, 0.9); }
  .ic-dot--done { background: rgba(255, 255, 255, 0.25); }
  .ic-dot--blocked { background: rgba(239, 68, 68, 0.85); }

  .ic-status-menu {
    position: absolute;
    top: calc(100% + 4px);
    left: 0;
    z-index: 50;
    background: rgba(20, 20, 24, 0.97);
    backdrop-filter: blur(16px);
    -webkit-backdrop-filter: blur(16px);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: var(--radius-sm, 6px);
    padding: 4px;
    min-width: 136px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .ic-status-opt {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 10px;
    border-radius: 4px;
    background: none;
    border: none;
    cursor: pointer;
    font-size: 0.75rem;
    color: var(--text-secondary, rgba(255, 255, 255, 0.6));
    text-align: left;
    transition: background 0.1s;
    width: 100%;
  }

  .ic-status-opt:hover {
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-primary, rgba(255, 255, 255, 0.9));
  }

  .ic-status-opt--active {
    color: var(--text-primary, rgba(255, 255, 255, 0.9));
    background: rgba(255, 255, 255, 0.05);
  }

  /* Title */
  .ic-title {
    flex: 1;
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }

  /* Labels */
  .ic-labels {
    display: flex;
    gap: 4px;
    flex-shrink: 0;
  }

  .ic-label {
    font-size: 0.625rem;
    font-weight: 500;
    padding: 2px 7px;
    border-radius: var(--radius-full, 9999px);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: var(--text-tertiary, rgba(255, 255, 255, 0.45));
    white-space: nowrap;
    max-width: 80px;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  /* Priority badge */
  .ic-priority {
    font-size: 0.625rem;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: var(--radius-full, 9999px);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    flex-shrink: 0;
  }

  .ic-priority--low {
    background: rgba(255, 255, 255, 0.05);
    color: rgba(255, 255, 255, 0.35);
    border: 1px solid rgba(255, 255, 255, 0.07);
  }

  .ic-priority--medium {
    background: rgba(234, 179, 8, 0.1);
    color: rgba(234, 179, 8, 0.8);
    border: 1px solid rgba(234, 179, 8, 0.15);
  }

  .ic-priority--high {
    background: rgba(249, 115, 22, 0.1);
    color: rgba(249, 115, 22, 0.85);
    border: 1px solid rgba(249, 115, 22, 0.15);
  }

  .ic-priority--critical {
    background: rgba(239, 68, 68, 0.1);
    color: rgba(239, 68, 68, 0.85);
    border: 1px solid rgba(239, 68, 68, 0.15);
  }

  /* Assignee avatar */
  .ic-assignee {
    width: 22px;
    height: 22px;
    border-radius: 50%;
    background: rgba(59, 130, 246, 0.15);
    border: 1px solid rgba(59, 130, 246, 0.25);
    color: rgba(59, 130, 246, 0.85);
    font-size: 0.5625rem;
    font-weight: 700;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }

  .ic-assignee--empty {
    background: rgba(255, 255, 255, 0.04);
    border-color: rgba(255, 255, 255, 0.06);
    color: var(--text-muted, rgba(255, 255, 255, 0.25));
    font-size: 0.625rem;
  }

  /* Age */
  .ic-age {
    font-size: 0.6875rem;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    flex-shrink: 0;
    min-width: 52px;
    text-align: right;
  }
</style>
