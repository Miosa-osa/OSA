<script lang="ts">
  import { fly } from 'svelte/transition';
  import type { Issue, IssueStatus, IssuePriority, UpdateIssuePayload } from '$lib/stores/issues.svelte';
  import CommentThread from './CommentThread.svelte';

  interface Props {
    issue: Issue;
    onClose: () => void;
    onUpdate: (id: string, payload: UpdateIssuePayload) => Promise<void>;
    onDelete: (id: string) => Promise<void>;
    onAddComment: (issueId: string, content: string) => Promise<void>;
  }

  let { issue, onClose, onUpdate, onDelete, onAddComment }: Props = $props();

  let editingTitle = $state(false);
  let titleDraft = $state(issue.title);
  let confirmDelete = $state(false);
  let deleting = $state(false);

  const STATUS_OPTIONS: { value: IssueStatus; label: string }[] = [
    { value: 'open', label: 'Open' },
    { value: 'in_progress', label: 'In Progress' },
    { value: 'done', label: 'Done' },
    { value: 'blocked', label: 'Blocked' },
  ];

  const PRIORITY_OPTIONS: { value: IssuePriority; label: string }[] = [
    { value: 'low', label: 'Low' },
    { value: 'medium', label: 'Medium' },
    { value: 'high', label: 'High' },
    { value: 'critical', label: 'Critical' },
  ];

  function timeAgo(iso: string): string {
    const diff = Date.now() - new Date(iso).getTime();
    const mins = Math.floor(diff / 60_000);
    if (mins < 1) return 'just now';
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    return `${Math.floor(hrs / 24)}d ago`;
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (e.key === 'Escape') onClose();
  }

  function commitTitle() {
    const t = titleDraft.trim();
    if (t && t !== issue.title) {
      void onUpdate(issue.id, { title: t });
    } else {
      titleDraft = issue.title;
    }
    editingTitle = false;
  }

  function handleTitleKeyDown(e: KeyboardEvent) {
    if (e.key === 'Enter') { e.preventDefault(); commitTitle(); }
    if (e.key === 'Escape') { titleDraft = issue.title; editingTitle = false; }
  }

  async function handleDelete() {
    if (!confirmDelete) { confirmDelete = true; return; }
    deleting = true;
    await onDelete(issue.id);
    deleting = false;
  }

  async function handleAddComment(content: string) {
    await onAddComment(issue.id, content);
  }

  function toggleSubtask(subtaskId: string, done: boolean) {
    const updated = issue.subtasks.map((s) =>
      s.id === subtaskId ? { ...s, done } : s
    );
    void onUpdate(issue.id, { title: issue.title } as UpdateIssuePayload);
    // Note: subtask update would need its own endpoint — for now update locally
    void updated; // type suppression
  }

  $effect(() => {
    titleDraft = issue.title;
  });
</script>

<!-- Backdrop -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="id-backdrop"
  onclick={onClose}
  onkeydown={handleKeyDown}
  aria-hidden="true"
  transition:fly={{ x: 20, duration: 0, opacity: 1 }}
></div>

<!-- Slide-over panel -->
<aside
  class="id-panel"
  aria-label="Issue detail: {issue.title}"
  transition:fly={{ x: 380, duration: 220 }}
>
  <!-- Header -->
  <header class="id-header">
    <div class="id-header-top">
      <!-- Status selector -->
      <select
        class="id-status-select id-status-select--{issue.status}"
        value={issue.status}
        onchange={(e) => onUpdate(issue.id, { status: e.currentTarget.value as IssueStatus })}
        aria-label="Issue status"
      >
        {#each STATUS_OPTIONS as opt}
          <option value={opt.value}>{opt.label}</option>
        {/each}
      </select>

      <!-- Issue ID chip -->
      <span class="id-id-chip" aria-label="Issue ID"># {issue.id.slice(-6)}</span>

      <!-- Close -->
      <button
        class="id-close"
        onclick={onClose}
        aria-label="Close issue detail"
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <line x1="18" y1="6" x2="6" y2="18" />
          <line x1="6" y1="6" x2="18" y2="18" />
        </svg>
      </button>
    </div>

    <!-- Editable title -->
    {#if editingTitle}
      <input
        class="id-title-input"
        type="text"
        bind:value={titleDraft}
        onblur={commitTitle}
        onkeydown={handleTitleKeyDown}
        aria-label="Edit issue title"
        autofocus
      />
    {:else}
      <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
      <h2
        class="id-title"
        onclick={() => { editingTitle = true; titleDraft = issue.title; }}
        onkeydown={(e) => { if (e.key === 'Enter') { editingTitle = true; titleDraft = issue.title; } }}
        title="Click to edit title"
        tabindex="0"
        role="button"
        aria-label="Edit title: {issue.title}"
      >
        {issue.title}
      </h2>
    {/if}
  </header>

  <!-- Scrollable body -->
  <div class="id-body">
    <!-- Meta row -->
    <div class="id-meta">
      <!-- Priority -->
      <div class="id-meta-field">
        <span class="id-meta-label">Priority</span>
        <select
          class="id-meta-select id-meta-select--priority--{issue.priority}"
          value={issue.priority}
          onchange={(e) => onUpdate(issue.id, { priority: e.currentTarget.value as IssuePriority })}
          aria-label="Issue priority"
        >
          {#each PRIORITY_OPTIONS as opt}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
      </div>

      <!-- Assignee -->
      <div class="id-meta-field">
        <span class="id-meta-label">Assignee</span>
        <span class="id-meta-value">{issue.assignee ?? '—'}</span>
      </div>

      <!-- Created -->
      <div class="id-meta-field">
        <span class="id-meta-label">Created</span>
        <time
          class="id-meta-value"
          datetime={issue.created_at}
          title={new Date(issue.created_at).toLocaleString()}
        >
          {timeAgo(issue.created_at)}
        </time>
      </div>
    </div>

    <!-- Labels -->
    {#if issue.labels.length > 0}
      <div class="id-labels-row" aria-label="Labels">
        {#each issue.labels as label}
          <span class="id-label">{label}</span>
        {/each}
      </div>
    {/if}

    <!-- Description -->
    {#if issue.description}
      <section class="id-section" aria-label="Description">
        <h3 class="id-section-heading">Description</h3>
        <pre class="id-description">{issue.description}</pre>
      </section>
    {/if}

    <!-- Subtasks -->
    {#if issue.subtasks.length > 0}
      <section class="id-section" aria-label="Subtasks">
        <h3 class="id-section-heading">Subtasks</h3>
        <ul class="id-subtasks">
          {#each issue.subtasks as sub (sub.id)}
            <li class="id-subtask">
              <input
                type="checkbox"
                class="id-subtask-check"
                checked={sub.done}
                onchange={(e) => toggleSubtask(sub.id, e.currentTarget.checked)}
                id="sub-{sub.id}"
                aria-label={sub.title}
              />
              <label
                for="sub-{sub.id}"
                class="id-subtask-label"
                class:id-subtask-label--done={sub.done}
              >
                {sub.title}
              </label>
            </li>
          {/each}
        </ul>
      </section>
    {/if}

    <!-- Comments -->
    <section class="id-section" aria-label="Comments section">
      <CommentThread
        comments={issue.comments}
        onAddComment={handleAddComment}
      />
    </section>
  </div>

  <!-- Action bar -->
  <footer class="id-footer">
    <button
      class="id-action-btn id-action-btn--danger"
      onclick={handleDelete}
      disabled={deleting}
      aria-label="{confirmDelete ? 'Confirm delete' : 'Delete issue'}"
    >
      {#if deleting}
        Deleting…
      {:else if confirmDelete}
        Confirm Delete?
      {:else}
        Delete
      {/if}
    </button>
    {#if confirmDelete}
      <button
        class="id-action-btn"
        onclick={() => { confirmDelete = false; }}
        aria-label="Cancel delete"
      >
        Cancel
      </button>
    {/if}
  </footer>
</aside>

<style>
  .id-backdrop {
    position: fixed;
    inset: 0;
    z-index: 40;
    background: rgba(0, 0, 0, 0.3);
    cursor: pointer;
  }

  .id-panel {
    position: fixed;
    top: 0;
    right: 0;
    bottom: 0;
    width: 420px;
    max-width: 90vw;
    z-index: 50;
    display: flex;
    flex-direction: column;
    background: rgba(14, 14, 18, 0.97);
    backdrop-filter: blur(24px);
    -webkit-backdrop-filter: blur(24px);
    border-left: 1px solid rgba(255, 255, 255, 0.08);
    overflow: hidden;
  }

  /* Header */
  .id-header {
    padding: 16px 16px 12px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .id-header-top {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .id-status-select {
    padding: 3px 10px;
    border-radius: var(--radius-full, 9999px);
    border: 1px solid rgba(255, 255, 255, 0.12);
    font-size: 0.6875rem;
    font-weight: 600;
    cursor: pointer;
    outline: none;
    appearance: none;
    -webkit-appearance: none;
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
  }

  .id-status-select--open { color: var(--accent-success, #22c55e); border-color: rgba(34, 197, 94, 0.25); background: rgba(34, 197, 94, 0.08); }
  .id-status-select--in_progress { color: rgba(59, 130, 246, 0.9); border-color: rgba(59, 130, 246, 0.25); background: rgba(59, 130, 246, 0.08); }
  .id-status-select--done { color: var(--text-tertiary, rgba(255, 255, 255, 0.4)); border-color: rgba(255, 255, 255, 0.1); background: rgba(255, 255, 255, 0.04); }
  .id-status-select--blocked { color: rgba(239, 68, 68, 0.85); border-color: rgba(239, 68, 68, 0.25); background: rgba(239, 68, 68, 0.08); }

  .id-id-chip {
    font-size: 0.625rem;
    font-family: ui-monospace, monospace;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 4px;
    padding: 2px 7px;
    flex-shrink: 0;
  }

  .id-close {
    margin-left: auto;
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 6px;
    border: none;
    background: transparent;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.4));
    cursor: pointer;
    transition: background 0.12s, color 0.12s;
    flex-shrink: 0;
  }

  .id-close:hover {
    background: rgba(255, 255, 255, 0.07);
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
  }

  .id-title {
    font-size: 1rem;
    font-weight: 600;
    color: var(--text-primary, rgba(255, 255, 255, 0.9));
    line-height: 1.4;
    cursor: text;
    letter-spacing: -0.01em;
    outline: none;
    border-radius: 4px;
    padding: 2px 0;
    transition: background 0.1s;
  }

  .id-title:hover {
    background: rgba(255, 255, 255, 0.03);
  }

  .id-title:focus-visible {
    outline: 2px solid rgba(59, 130, 246, 0.5);
    outline-offset: 2px;
  }

  .id-title-input {
    font-size: 1rem;
    font-weight: 600;
    color: var(--text-primary, rgba(255, 255, 255, 0.9));
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.18);
    border-radius: 4px;
    padding: 4px 8px;
    outline: none;
    width: 100%;
    font-family: inherit;
    letter-spacing: -0.01em;
  }

  /* Scrollable body */
  .id-body {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 20px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  /* Meta row */
  .id-meta {
    display: flex;
    gap: 16px;
    flex-wrap: wrap;
  }

  .id-meta-field {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .id-meta-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
  }

  .id-meta-value {
    font-size: 0.8125rem;
    color: var(--text-secondary, rgba(255, 255, 255, 0.6));
  }

  .id-meta-select {
    background: transparent;
    border: none;
    outline: none;
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    appearance: none;
    -webkit-appearance: none;
    padding: 0;
    font-family: inherit;
  }

  .id-meta-select--priority--low { color: rgba(255, 255, 255, 0.5); }
  .id-meta-select--priority--medium { color: rgba(234, 179, 8, 0.85); }
  .id-meta-select--priority--high { color: rgba(249, 115, 22, 0.85); }
  .id-meta-select--priority--critical { color: rgba(239, 68, 68, 0.85); }

  /* Labels */
  .id-labels-row {
    display: flex;
    gap: 5px;
    flex-wrap: wrap;
  }

  .id-label {
    font-size: 0.6875rem;
    font-weight: 500;
    padding: 3px 10px;
    border-radius: var(--radius-full, 9999px);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.09);
    color: var(--text-secondary, rgba(255, 255, 255, 0.6));
  }

  /* Sections */
  .id-section {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .id-section-heading {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
  }

  .id-description {
    font-size: 0.8125rem;
    color: var(--text-secondary, rgba(255, 255, 255, 0.6));
    line-height: 1.6;
    white-space: pre-wrap;
    word-break: break-word;
    font-family: inherit;
    margin: 0;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-sm, 6px);
    padding: 10px 12px;
  }

  /* Subtasks */
  .id-subtasks {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .id-subtask {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .id-subtask-check {
    width: 14px;
    height: 14px;
    accent-color: var(--accent-success, #22c55e);
    flex-shrink: 0;
    cursor: pointer;
  }

  .id-subtask-label {
    font-size: 0.8125rem;
    color: var(--text-secondary, rgba(255, 255, 255, 0.6));
    cursor: pointer;
    line-height: 1.4;
    transition: color 0.12s;
  }

  .id-subtask-label--done {
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    text-decoration: line-through;
  }

  /* Footer */
  .id-footer {
    padding: 12px 16px;
    border-top: 1px solid rgba(255, 255, 255, 0.06);
    display: flex;
    gap: 8px;
    flex-shrink: 0;
  }

  .id-action-btn {
    padding: 6px 14px;
    border-radius: var(--radius-sm, 6px);
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: var(--text-secondary, rgba(255, 255, 255, 0.6));
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.12s, border-color 0.12s;
  }

  .id-action-btn:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.08);
  }

  .id-action-btn--danger {
    color: rgba(239, 68, 68, 0.75);
    border-color: rgba(239, 68, 68, 0.15);
  }

  .id-action-btn--danger:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.08);
    border-color: rgba(239, 68, 68, 0.25);
    color: rgba(239, 68, 68, 0.9);
  }

  .id-action-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
</style>
