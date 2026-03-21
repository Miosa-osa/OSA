<script lang="ts">
  import { slide } from 'svelte/transition';
  import type { Issue, CreateIssuePayload, IssuePriority } from '$lib/stores/issues.svelte';

  interface Props {
    onSubmit: (payload: CreateIssuePayload) => Promise<void>;
    onCancel: () => void;
    editIssue?: Issue;
  }

  let { onSubmit, onCancel, editIssue }: Props = $props();

  let title = $state(editIssue?.title ?? '');
  let description = $state(editIssue?.description ?? '');
  let priority = $state<IssuePriority>(editIssue?.priority ?? 'medium');
  let labelsRaw = $state((editIssue?.labels ?? []).join(', '));
  let assignee = $state(editIssue?.assignee ?? '');
  let titleError = $state('');
  let submitting = $state(false);

  const PRIORITIES: { value: IssuePriority; label: string }[] = [
    { value: 'low', label: 'Low' },
    { value: 'medium', label: 'Medium' },
    { value: 'high', label: 'High' },
    { value: 'critical', label: 'Critical' },
  ];

  async function handleSubmit() {
    titleError = '';
    const t = title.trim();
    if (!t) {
      titleError = 'Title is required.';
      return;
    }
    submitting = true;
    try {
      const labels = labelsRaw
        .split(',')
        .map((l) => l.trim())
        .filter(Boolean);

      const payload: CreateIssuePayload = {
        title: t,
        priority,
      };
      if (description.trim()) payload.description = description.trim();
      if (labels.length > 0) payload.labels = labels;
      if (assignee.trim()) payload.assignee = assignee.trim();

      await onSubmit(payload);
    } finally {
      submitting = false;
    }
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (e.key === 'Escape') onCancel();
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="if-wrapper"
  transition:slide={{ duration: 200 }}
  onkeydown={handleKeyDown}
>
  <div class="if-form" role="form" aria-label="{editIssue ? 'Edit' : 'Create'} issue">
    <div class="if-row">
      <div class="if-field if-field--full">
        <label class="if-label" for="if-title">Title <span class="if-required" aria-hidden="true">*</span></label>
        <input
          id="if-title"
          class="if-input"
          class:if-input--error={!!titleError}
          type="text"
          placeholder="Short, descriptive title"
          bind:value={title}
          aria-required="true"
          aria-describedby={titleError ? 'if-title-err' : undefined}
          autofocus
        />
        {#if titleError}
          <span id="if-title-err" class="if-error" role="alert">{titleError}</span>
        {/if}
      </div>
    </div>

    <div class="if-row">
      <div class="if-field if-field--full">
        <label class="if-label" for="if-desc">Description</label>
        <textarea
          id="if-desc"
          class="if-textarea"
          placeholder="What needs to be done? Provide context for the agent."
          bind:value={description}
          rows={3}
          aria-label="Description"
        ></textarea>
      </div>
    </div>

    <div class="if-row if-row--split">
      <!-- Priority -->
      <fieldset class="if-field">
        <legend class="if-label">Priority</legend>
        <div class="if-pills" role="group" aria-label="Select priority">
          {#each PRIORITIES as p}
            <button
              type="button"
              class="if-pill if-pill--{p.value}"
              class:if-pill--active={priority === p.value}
              onclick={() => { priority = p.value; }}
              aria-pressed={priority === p.value}
            >
              {p.label}
            </button>
          {/each}
        </div>
      </fieldset>

      <!-- Assignee -->
      <div class="if-field">
        <label class="if-label" for="if-assignee">Assignee</label>
        <input
          id="if-assignee"
          class="if-input"
          type="text"
          placeholder="Agent name or ID"
          bind:value={assignee}
          aria-label="Assignee"
        />
      </div>
    </div>

    <div class="if-row">
      <div class="if-field if-field--full">
        <label class="if-label" for="if-labels">Labels</label>
        <input
          id="if-labels"
          class="if-input"
          type="text"
          placeholder="bug, feature, agent-task (comma separated)"
          bind:value={labelsRaw}
          aria-label="Labels, comma separated"
        />
      </div>
    </div>

    <div class="if-actions">
      <button
        class="if-cancel"
        type="button"
        onclick={onCancel}
        aria-label="Cancel"
      >
        Cancel
      </button>
      <button
        class="if-submit"
        type="button"
        onclick={handleSubmit}
        disabled={submitting}
        aria-label="{editIssue ? 'Save changes' : 'Create issue'}"
      >
        {#if submitting}
          <span class="if-spinner" aria-hidden="true"></span>
        {/if}
        {editIssue ? 'Save Changes' : 'Create Issue'}
      </button>
    </div>
  </div>
</div>

<style>
  .if-wrapper {
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md, 8px);
    overflow: hidden;
  }

  .if-form {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 16px;
  }

  .if-row {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .if-row--split {
    flex-direction: row;
    gap: 16px;
    flex-wrap: wrap;
  }

  .if-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
    border: none;
    padding: 0;
    margin: 0;
    min-width: 0;
  }

  .if-field--full {
    flex: 1;
  }

  .if-label {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.4));
  }

  .if-required {
    color: rgba(239, 68, 68, 0.7);
    margin-left: 2px;
  }

  .if-input {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: var(--radius-sm, 6px);
    padding: 8px 12px;
    font-size: 0.8125rem;
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
    outline: none;
    width: 100%;
    transition: border-color 0.15s;
    font-family: inherit;
  }

  .if-input::placeholder { color: var(--text-muted, rgba(255, 255, 255, 0.28)); }
  .if-input:focus { border-color: rgba(255, 255, 255, 0.18); }
  .if-input--error { border-color: rgba(239, 68, 68, 0.5); }

  .if-textarea {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: var(--radius-sm, 6px);
    padding: 8px 12px;
    font-size: 0.8125rem;
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
    outline: none;
    width: 100%;
    resize: vertical;
    font-family: inherit;
    line-height: 1.5;
    transition: border-color 0.15s;
    min-height: 72px;
  }

  .if-textarea::placeholder { color: var(--text-muted, rgba(255, 255, 255, 0.28)); }
  .if-textarea:focus { border-color: rgba(255, 255, 255, 0.18); }

  .if-error {
    font-size: 0.6875rem;
    color: rgba(239, 68, 68, 0.85);
  }

  /* Priority pills */
  .if-pills {
    display: flex;
    gap: 4px;
    flex-wrap: wrap;
  }

  .if-pill {
    padding: 4px 12px;
    border-radius: var(--radius-full, 9999px);
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.12s;
    border: 1px solid transparent;
    background: rgba(255, 255, 255, 0.04);
    color: var(--text-tertiary, rgba(255, 255, 255, 0.4));
  }

  .if-pill:hover {
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-secondary, rgba(255, 255, 255, 0.6));
  }

  .if-pill--low.if-pill--active {
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.7);
    border-color: rgba(255, 255, 255, 0.15);
  }

  .if-pill--medium.if-pill--active {
    background: rgba(234, 179, 8, 0.12);
    color: rgba(234, 179, 8, 0.9);
    border-color: rgba(234, 179, 8, 0.25);
  }

  .if-pill--high.if-pill--active {
    background: rgba(249, 115, 22, 0.12);
    color: rgba(249, 115, 22, 0.9);
    border-color: rgba(249, 115, 22, 0.25);
  }

  .if-pill--critical.if-pill--active {
    background: rgba(239, 68, 68, 0.12);
    color: rgba(239, 68, 68, 0.9);
    border-color: rgba(239, 68, 68, 0.25);
  }

  /* Actions */
  .if-actions {
    display: flex;
    gap: 8px;
    justify-content: flex-end;
    padding-top: 4px;
  }

  .if-cancel {
    padding: 6px 14px;
    border-radius: var(--radius-sm, 6px);
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: var(--text-secondary, rgba(255, 255, 255, 0.6));
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.12s;
  }

  .if-cancel:hover { background: rgba(255, 255, 255, 0.05); }

  .if-submit {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 16px;
    border-radius: var(--radius-sm, 6px);
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.14);
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
    font-size: 0.8125rem;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.12s, opacity 0.12s;
  }

  .if-submit:hover:not(:disabled) { background: rgba(255, 255, 255, 0.15); }
  .if-submit:disabled { opacity: 0.4; cursor: not-allowed; }

  .if-spinner {
    width: 12px;
    height: 12px;
    border: 1.5px solid rgba(255, 255, 255, 0.15);
    border-top-color: rgba(255, 255, 255, 0.7);
    border-radius: 50%;
    animation: if-spin 0.7s linear infinite;
  }

  @keyframes if-spin { to { transform: rotate(360deg); } }
</style>
