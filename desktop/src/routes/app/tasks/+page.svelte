<script lang="ts">
  import { onMount }              from 'svelte';
  import { slide }                from 'svelte/transition';
  import { scheduledTasksStore }  from '$lib/stores/scheduledTasks.svelte';
  import ScheduledTaskList        from '$lib/components/tasks/ScheduledTaskList.svelte';
  import RunHistory               from '$lib/components/tasks/RunHistory.svelte';
  import RunDetail                from '$lib/components/tasks/RunDetail.svelte';
  import type { ScheduledTask }   from '$lib/stores/scheduledTasks.svelte';
  import type { ScheduledRun }    from '$lib/api/types';

  // ── State ────────────────────────────────────────────────────────────────────

  type PageTab = 'scheduled' | 'history';

  let activeTab   = $state<PageTab>('scheduled');
  let showForm    = $state(false);
  let editingTask = $state<ScheduledTask | null>(null);

  let activeRunTask = $derived(
    scheduledTasksStore.activeRun
      ? scheduledTasksStore.tasks.find(
          (t) => t.id === scheduledTasksStore.activeRun?.scheduled_task_id,
        )
      : null,
  );

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  onMount(() => {
    scheduledTasksStore.fetchTasks();
    scheduledTasksStore.fetchPresets();
  });

  // ── Handlers ─────────────────────────────────────────────────────────────────

  function openNewForm() {
    editingTask = null;
    showForm    = true;
  }

  function openEditForm(id: string) {
    editingTask = scheduledTasksStore.tasks.find((t) => t.id === id) ?? null;
    showForm    = true;
  }

  function closeForm() {
    showForm    = false;
    editingTask = null;
  }

  async function handleSubmit(payload: Parameters<typeof scheduledTasksStore.createTask>[0]) {
    await scheduledTasksStore.createTask(payload);
    closeForm();
  }

  async function handleRunNow(id: string) {
    const run = await scheduledTasksStore.triggerNow(id);
    if (run && run.status === 'running') {
      scheduledTasksStore.streamRun(run.scheduled_task_id, run.id);
    }
  }

  function switchToHistory() {
    activeTab = 'history';
    scheduledTasksStore.fetchRuns();
  }

  function handleSelectRun(run: ScheduledRun) {
    scheduledTasksStore.fetchRun(run.scheduled_task_id, run.id);
    if (run.status === 'running') {
      scheduledTasksStore.streamRun(run.scheduled_task_id, run.id);
    }
  }

  async function handleRerun(taskId: string) {
    scheduledTasksStore.closeRunDetail();
    await handleRunNow(taskId);
  }
</script>

<div class="tp-page">

  <!-- Header -->
  <header class="tp-header">
    <div class="tp-header-left">
      <h1 class="tp-title">Tasks</h1>
      <span class="tp-subtitle">Scheduled jobs, cron automation, and run history</span>
    </div>

    <div class="tp-header-right">
      {#if scheduledTasksStore.tasks.length > 0}
        <div class="tp-stats-bar" role="status" aria-label="Task statistics">
          <span class="tp-stat tp-stat--active">
            <span class="tp-stat-dot tp-stat-dot--active" aria-hidden="true"></span>
            <span class="tp-stat-value">{scheduledTasksStore.activeCount}</span>
            <span class="tp-stat-label">active</span>
          </span>
          {#if scheduledTasksStore.pausedCount > 0}
            <span class="tp-stat-divider" aria-hidden="true"></span>
            <span class="tp-stat">
              <span class="tp-stat-value">{scheduledTasksStore.pausedCount}</span>
              <span class="tp-stat-label">paused</span>
            </span>
          {/if}
          {#if scheduledTasksStore.failedCount > 0}
            <span class="tp-stat-divider" aria-hidden="true"></span>
            <span class="tp-stat tp-stat--failed">
              <span class="tp-stat-value">{scheduledTasksStore.failedCount}</span>
              <span class="tp-stat-label">failed</span>
            </span>
          {/if}
        </div>
      {/if}

      {#if activeTab === 'scheduled'}
        <button
          class="tp-new-btn"
          onclick={openNewForm}
          aria-label="Create new scheduled task"
          aria-expanded={showForm && editingTask === null}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor"
            stroke-width="2" stroke-linecap="round" aria-hidden="true">
            <line x1="6" y1="1" x2="6" y2="11"/>
            <line x1="1" y1="6" x2="11" y2="6"/>
          </svg>
          New Task
        </button>
      {/if}
    </div>
  </header>

  <!-- Page tabs -->
  <nav class="tp-tabs" aria-label="Task sections">
    <button
      class="tp-tab"
      class:tp-tab--active={activeTab === 'scheduled'}
      onclick={() => { activeTab = 'scheduled'; }}
      aria-pressed={activeTab === 'scheduled'}
    >
      Scheduled Tasks
    </button>
    <button
      class="tp-tab"
      class:tp-tab--active={activeTab === 'history'}
      onclick={switchToHistory}
      aria-pressed={activeTab === 'history'}
    >
      Run History
    </button>
  </nav>

  <!-- Content -->
  <main class="tp-content" id="tasks-main">

    {#if activeTab === 'scheduled'}
      <ScheduledTaskList
        {showForm}
        {editingTask}
        onCloseForm={closeForm}
        onOpenNewForm={openNewForm}
        onPause={(id) => scheduledTasksStore.pauseTask(id)}
        onResume={(id) => scheduledTasksStore.resumeTask(id)}
        onDelete={(id) => scheduledTasksStore.deleteTask(id)}
        onEdit={openEditForm}
        onRunNow={handleRunNow}
        onSubmit={handleSubmit}
      />

    {:else if activeTab === 'history'}
      {#if scheduledTasksStore.activeRun}
        <div transition:slide={{ duration: 180 }}>
          <RunDetail
            run={scheduledTasksStore.activeRun}
            taskName={activeRunTask?.name}
            onClose={() => scheduledTasksStore.closeRunDetail()}
            onRerun={handleRerun}
          />
        </div>
      {/if}
      <RunHistory onSelectRun={handleSelectRun} />
    {/if}

  </main>
</div>

<style>
  .tp-page { display: flex; flex-direction: column; height: 100%; overflow: hidden; background: var(--bg-secondary); }

  .tp-header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 20px 24px 16px; border-bottom: 1px solid rgba(255,255,255,.05);
    flex-shrink: 0; gap: 16px; flex-wrap: wrap;
  }
  .tp-header-left { display: flex; flex-direction: column; gap: 2px; }
  .tp-title { font-size: 1.125rem; font-weight: 600; color: var(--text-primary); letter-spacing: -.01em; }
  .tp-subtitle { font-size: .75rem; color: var(--text-tertiary); }
  .tp-header-right { display: flex; align-items: center; gap: 12px; }

  .tp-stats-bar {
    display: flex; align-items: center; gap: 10px;
    background: rgba(255,255,255,.04); border: 1px solid rgba(255,255,255,.06);
    border-radius: var(--radius-full); padding: 5px 14px;
  }
  .tp-stat { display: flex; align-items: center; gap: 5px; }
  .tp-stat--active .tp-stat-value { color: var(--accent-success); }
  .tp-stat--failed .tp-stat-value  { color: var(--accent-error); }
  .tp-stat-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--text-tertiary); }
  .tp-stat-dot--active { background: var(--accent-success); animation: tp-pulse 2s ease-in-out infinite; }
  @keyframes tp-pulse { 0%,100%{opacity:1;transform:scale(1)} 50%{opacity:.6;transform:scale(.8)} }
  .tp-stat-value { font-size: .8125rem; font-weight: 600; color: var(--text-primary); font-variant-numeric: tabular-nums; }
  .tp-stat-label { font-size: .6875rem; color: var(--text-tertiary); text-transform: uppercase; letter-spacing: .05em; }
  .tp-stat-divider { width: 1px; height: 12px; background: rgba(255,255,255,.08); }

  .tp-new-btn {
    display: flex; align-items: center; gap: 7px; padding: 7px 16px;
    background: rgba(255,255,255,.08); border: 1px solid rgba(255,255,255,.12);
    border-radius: var(--radius-sm); color: var(--text-primary); font-size: .8125rem;
    font-weight: 500; cursor: pointer; transition: background .15s, border-color .15s; flex-shrink: 0;
  }
  .tp-new-btn:hover { background: rgba(255,255,255,.12); border-color: rgba(255,255,255,.2); }

  .tp-tabs { display: flex; align-items: center; padding: 0 24px; border-bottom: 1px solid rgba(255,255,255,.05); flex-shrink: 0; }
  .tp-tab {
    padding: 10px 18px; background: none; border: none; border-bottom: 2px solid transparent;
    color: var(--text-tertiary); font-size: .8125rem; font-weight: 500; cursor: pointer;
    transition: color .15s, border-color .15s;
  }
  .tp-tab:hover:not(.tp-tab--active) { color: var(--text-secondary); }
  .tp-tab--active { color: var(--text-primary); border-bottom-color: var(--text-primary); }

  .tp-content {
    flex: 1; overflow-y: auto; padding: 16px 24px 24px;
    scrollbar-width: thin; scrollbar-color: rgba(255,255,255,.08) transparent;
    display: flex; flex-direction: column; gap: 12px;
  }
</style>
