<script lang="ts">
  import { slide } from 'svelte/transition';
  import { scheduledTasksStore } from '$lib/stores/scheduledTasks.svelte';
  import ScheduledTaskCard from '$lib/components/tasks/ScheduledTaskCard.svelte';
  import ScheduledTaskForm from '$lib/components/tasks/ScheduledTaskForm.svelte';
  import type { ScheduledTask } from '$lib/stores/scheduledTasks.svelte';

  // ── Types ─────────────────────────────────────────────────────────────────

  type FilterTab = 'all' | 'active' | 'paused' | 'failed';

  const FILTERS: { id: FilterTab; label: string }[] = [
    { id: 'all',    label: 'All'    },
    { id: 'active', label: 'Active' },
    { id: 'paused', label: 'Paused' },
    { id: 'failed', label: 'Failed' },
  ];

  // ── Props ──────────────────────────────────────────────────────────────────

  interface Props {
    showForm: boolean;
    onCloseForm: () => void;
    onOpenNewForm: () => void;
    onPause: (id: string) => void;
    onResume: (id: string) => void;
    onDelete: (id: string) => void;
    onEdit: (id: string) => void;
    onRunNow: (id: string) => void;
    onSubmit: (payload: Parameters<typeof scheduledTasksStore.createTask>[0]) => void;
    editingTask: ScheduledTask | null;
  }

  let {
    showForm,
    onCloseForm,
    onOpenNewForm,
    onPause,
    onResume,
    onDelete,
    onEdit,
    onRunNow,
    onSubmit,
    editingTask,
  }: Props = $props();

  // ── State ──────────────────────────────────────────────────────────────────

  let activeFilter = $state<FilterTab>('all');

  // ── Derived ───────────────────────────────────────────────────────────────

  let visibleTasks = $derived(
    activeFilter === 'all'
      ? scheduledTasksStore.tasks
      : scheduledTasksStore.tasks.filter((t) => t.status === activeFilter),
  );

  function countFor(tab: FilterTab): number {
    if (tab === 'all') return scheduledTasksStore.tasks.length;
    return scheduledTasksStore.tasks.filter((t) => t.status === tab).length;
  }
</script>

<!-- Filter tabs -->
<nav class="stl-filter-nav" aria-label="Filter scheduled tasks by status">
  {#each FILTERS as tab}
    <button
      class="stl-filter-tab"
      class:stl-filter-tab--active={activeFilter === tab.id}
      onclick={() => { activeFilter = tab.id; }}
      aria-pressed={activeFilter === tab.id}
      aria-label="Show {tab.label.toLowerCase()} tasks"
    >
      {tab.label}
      {#if countFor(tab.id) > 0}
        <span class="stl-filter-count" aria-hidden="true">{countFor(tab.id)}</span>
      {/if}
    </button>
  {/each}
</nav>

<!-- Inline form -->
{#if showForm}
  <div transition:slide={{ duration: 180 }} class="stl-form-wrapper">
    <ScheduledTaskForm
      task={editingTask}
      onSubmit={onSubmit}
      onCancel={onCloseForm}
    />
  </div>
{/if}

<!-- Loading -->
{#if scheduledTasksStore.loading && scheduledTasksStore.tasks.length === 0}
  <div class="stl-empty" role="status" aria-label="Loading tasks">
    <span class="stl-spinner" aria-hidden="true"></span>
    <p class="stl-empty-title">Loading tasks</p>
  </div>

<!-- Empty -->
{:else if visibleTasks.length === 0}
  <div class="stl-empty" role="status">
    <div class="stl-empty-icon" aria-hidden="true">
      <svg width="44" height="44" viewBox="0 0 44 44" fill="none" xmlns="http://www.w3.org/2000/svg">
        <rect x="6" y="8" width="32" height="28" rx="4" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.3"/>
        <circle cx="22" cy="22" r="7" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.5"/>
        <line x1="22" y1="15" x2="22" y2="22" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.7"/>
        <line x1="22" y1="22" x2="26" y2="25" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.7"/>
      </svg>
    </div>
    {#if activeFilter === 'all'}
      <p class="stl-empty-title">No scheduled tasks</p>
      <p class="stl-empty-subtitle">
        Create a task to automate recurring jobs using cron expressions.
      </p>
      <button class="stl-empty-cta" onclick={onOpenNewForm} aria-label="Create first scheduled task">
        Create your first task
      </button>
    {:else}
      <p class="stl-empty-title">No {activeFilter} tasks</p>
      <p class="stl-empty-subtitle">No tasks match the "{activeFilter}" filter.</p>
    {/if}
  </div>

<!-- Task list -->
{:else}
  <div class="stl-task-list" role="list" aria-label="Scheduled tasks">
    {#each visibleTasks as task (task.id)}
      <div role="listitem">
        <ScheduledTaskCard
          {task}
          onPause={onPause}
          onResume={onResume}
          onDelete={onDelete}
          onEdit={onEdit}
          onRunNow={onRunNow}
        />
      </div>
    {/each}
  </div>
{/if}

<style>
  /* ── Filter nav ──────────────────────────────────────────────────────────── */
  .stl-filter-nav {
    display: flex;
    align-items: center;
    gap: 4px;
    margin-bottom: 4px;
  }

  .stl-filter-tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 12px;
    border-radius: var(--radius-sm);
    background: none;
    border: 1px solid transparent;
    color: var(--text-tertiary);
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: color 0.15s, background 0.15s;
  }

  .stl-filter-tab:hover:not(.stl-filter-tab--active) {
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.04);
  }

  .stl-filter-tab--active {
    color: var(--text-primary);
    background: rgba(255, 255, 255, 0.06);
    border-color: rgba(255, 255, 255, 0.1);
  }

  .stl-filter-count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 18px;
    height: 18px;
    padding: 0 5px;
    background: rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-full);
    font-size: 0.625rem;
    font-weight: 600;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
  }

  .stl-filter-tab--active .stl-filter-count {
    background: rgba(255, 255, 255, 0.12);
    color: var(--text-secondary);
  }

  /* ── Form wrapper ────────────────────────────────────────────────────────── */
  .stl-form-wrapper {
    margin-bottom: 4px;
  }

  /* ── Task list ───────────────────────────────────────────────────────────── */
  .stl-task-list {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 10px;
    align-content: start;
  }

  @media (max-width: 720px) {
    .stl-task-list { grid-template-columns: 1fr; }
  }

  /* ── Empty state ─────────────────────────────────────────────────────────── */
  .stl-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 300px;
    gap: 10px;
    color: var(--text-tertiary);
    text-align: center;
    padding: 48px 32px;
  }

  .stl-empty-icon {
    color: rgba(255, 255, 255, 0.1);
    margin-bottom: 8px;
  }

  .stl-empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .stl-empty-subtitle {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    max-width: 300px;
    line-height: 1.55;
  }

  .stl-empty-cta {
    margin-top: 8px;
    padding: 8px 20px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
  }

  .stl-empty-cta:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
  }

  /* ── Loading spinner ─────────────────────────────────────────────────────── */
  .stl-spinner {
    display: block;
    width: 16px;
    height: 16px;
    border: 2px solid rgba(255, 255, 255, 0.08);
    border-top-color: rgba(255, 255, 255, 0.4);
    border-radius: 50%;
    animation: stl-spin 0.8s linear infinite;
    margin-bottom: 4px;
  }

  @keyframes stl-spin {
    to { transform: rotate(360deg); }
  }
</style>
