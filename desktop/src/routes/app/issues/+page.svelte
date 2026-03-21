<script lang="ts">
  import { onMount } from 'svelte';
  import { issuesStore } from '$lib/stores/issues.svelte';
  import type { Issue, IssueStatus, CreateIssuePayload } from '$lib/stores/issues.svelte';
  import IssueList from '$lib/components/issues/IssueList.svelte';
  import IssueDetail from '$lib/components/issues/IssueDetail.svelte';
  import IssueForm from '$lib/components/issues/IssueForm.svelte';

  type FilterTab = 'all' | IssueStatus;

  const TABS: { id: FilterTab; label: string; count: () => number }[] = [
    { id: 'all',         label: 'All',         count: () => issuesStore.issues.length },
    { id: 'open',        label: 'Open',        count: () => issuesStore.openCount },
    { id: 'in_progress', label: 'In Progress', count: () => issuesStore.inProgressCount },
    { id: 'done',        label: 'Done',        count: () => issuesStore.doneCount },
    { id: 'blocked',     label: 'Blocked',     count: () => issuesStore.blockedCount },
  ];

  let activeTab = $state<FilterTab>('all');
  let showForm = $state(false);

  const visibleIssues = $derived(
    activeTab === 'all'
      ? issuesStore.filteredIssues
      : issuesStore.filteredIssues.filter((i) => i.status === activeTab),
  );

  onMount(() => {
    void issuesStore.fetchIssues();
  });

  function handleTabChange(tab: FilterTab) {
    activeTab = tab;
  }

  function handleSelect(issue: Issue) {
    issuesStore.selectIssue(issue);
  }

  async function handleStatusChange(id: string, status: IssueStatus) {
    await issuesStore.updateIssue(id, { status });
  }

  async function handleCreate(payload: CreateIssuePayload) {
    await issuesStore.createIssue(payload);
    showForm = false;
  }

  async function handleUpdate(id: string, payload: import('$lib/stores/issues.svelte').UpdateIssuePayload) {
    await issuesStore.updateIssue(id, payload);
  }

  async function handleDelete(id: string) {
    await issuesStore.deleteIssue(id);
  }

  async function handleAddComment(issueId: string, content: string) {
    await issuesStore.addComment(issueId, content);
  }
</script>

<div class="ip-page">
  <!-- Page header -->
  <header class="ip-header">
    <div class="ip-header-left">
      <h1 class="ip-title">Issues</h1>
      <span class="ip-subtitle">Agent work inbox</span>
    </div>

    <div class="ip-header-right">
      {#if issuesStore.issues.length > 0}
        <div class="ip-stats" role="status" aria-label="Issue statistics">
          {#if issuesStore.openCount > 0}
            <span class="ip-stat">
              <span class="ip-stat-dot ip-stat-dot--open" aria-hidden="true"></span>
              <span class="ip-stat-val">{issuesStore.openCount}</span>
              <span class="ip-stat-label">open</span>
            </span>
          {/if}
          {#if issuesStore.inProgressCount > 0}
            <span class="ip-stat-divider" aria-hidden="true"></span>
            <span class="ip-stat">
              <span class="ip-stat-dot ip-stat-dot--in_progress" aria-hidden="true"></span>
              <span class="ip-stat-val">{issuesStore.inProgressCount}</span>
              <span class="ip-stat-label">in progress</span>
            </span>
          {/if}
          {#if issuesStore.blockedCount > 0}
            <span class="ip-stat-divider" aria-hidden="true"></span>
            <span class="ip-stat">
              <span class="ip-stat-dot ip-stat-dot--blocked" aria-hidden="true"></span>
              <span class="ip-stat-val">{issuesStore.blockedCount}</span>
              <span class="ip-stat-label">blocked</span>
            </span>
          {/if}
        </div>
      {/if}

      <button
        class="ip-new-btn"
        onclick={() => { showForm = !showForm; }}
        aria-label="Create new issue"
        aria-expanded={showForm}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true">
          <line x1="6" y1="1" x2="6" y2="11"/>
          <line x1="1" y1="6" x2="11" y2="6"/>
        </svg>
        New Issue
      </button>
    </div>
  </header>

  <!-- Filter tabs -->
  <nav class="ip-tabs" aria-label="Filter issues by status">
    {#each TABS as tab}
      <button
        class="ip-tab"
        class:ip-tab--active={activeTab === tab.id}
        onclick={() => handleTabChange(tab.id)}
        aria-pressed={activeTab === tab.id}
      >
        {tab.label}
        {#if tab.count() > 0}
          <span class="ip-tab-count" aria-hidden="true">{tab.count()}</span>
        {/if}
      </button>
    {/each}
  </nav>

  <!-- Content -->
  <main class="ip-content">
    <!-- Error banner -->
    {#if issuesStore.error}
      <div class="ip-error-banner" role="alert">
        <span class="ip-error-dot" aria-hidden="true"></span>
        <span class="ip-error-text">{issuesStore.error}</span>
        <button
          class="ip-error-retry"
          onclick={() => void issuesStore.fetchIssues()}
          aria-label="Retry loading issues"
        >
          Retry
        </button>
      </div>
    {/if}

    <!-- Create form -->
    {#if showForm}
      <IssueForm
        onSubmit={handleCreate}
        onCancel={() => { showForm = false; }}
      />
    {/if}

    <!-- Loading -->
    {#if issuesStore.loading && issuesStore.issues.length === 0}
      <div class="ip-loading" role="status" aria-label="Loading issues">
        <span class="ip-spinner" aria-hidden="true"></span>
        <p class="ip-loading-text">Loading issues</p>
      </div>
    {:else}
      <IssueList
        issues={visibleIssues}
        onSelect={handleSelect}
        onStatusChange={handleStatusChange}
      />
    {/if}
  </main>
</div>

<!-- Detail panel (rendered outside main so it can overlay) -->
{#if issuesStore.selectedIssue}
  <IssueDetail
    issue={issuesStore.selectedIssue}
    onClose={() => issuesStore.selectIssue(null)}
    onUpdate={handleUpdate}
    onDelete={handleDelete}
    onAddComment={handleAddComment}
  />
{/if}

<style>
  .ip-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  /* Header */
  .ip-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 24px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
    gap: 16px;
    flex-wrap: wrap;
  }

  .ip-header-left {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .ip-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
  }

  .ip-subtitle {
    font-size: 0.75rem;
    color: var(--text-tertiary);
  }

  .ip-header-right {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }

  /* Stats */
  .ip-stats {
    display: flex;
    align-items: center;
    gap: 8px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    padding: 5px 14px;
  }

  .ip-stat {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  .ip-stat-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
  }

  .ip-stat-dot--open { background: var(--accent-success, #22c55e); }
  .ip-stat-dot--in_progress { background: rgba(59, 130, 246, 0.9); }
  .ip-stat-dot--blocked { background: rgba(239, 68, 68, 0.85); }

  .ip-stat-val {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  .ip-stat-label {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .ip-stat-divider {
    width: 1px;
    height: 12px;
    background: rgba(255, 255, 255, 0.08);
  }

  /* New button */
  .ip-new-btn {
    display: flex;
    align-items: center;
    gap: 7px;
    padding: 7px 16px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .ip-new-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
  }

  /* Filter tabs */
  .ip-tabs {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 10px 24px 0;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .ip-tabs::-webkit-scrollbar { display: none; }

  .ip-tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    border-radius: var(--radius-sm) var(--radius-sm) 0 0;
    background: none;
    border: none;
    color: var(--text-tertiary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: color 0.15s, background 0.15s;
    position: relative;
    bottom: -1px;
    white-space: nowrap;
  }

  .ip-tab:hover:not(.ip-tab--active) {
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.04);
  }

  .ip-tab--active {
    color: var(--text-primary);
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-bottom-color: var(--bg-secondary);
  }

  .ip-tab-count {
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

  .ip-tab--active .ip-tab-count {
    background: rgba(255, 255, 255, 0.12);
    color: var(--text-secondary);
  }

  /* Content */
  .ip-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  /* Error banner */
  .ip-error-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
  }

  .ip-error-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .ip-error-text { color: var(--text-secondary); flex: 1; }

  .ip-error-retry {
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s;
  }

  .ip-error-retry:hover {
    background: rgba(255, 255, 255, 0.12);
    color: var(--text-primary);
  }

  /* Loading */
  .ip-loading {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 200px;
    gap: 10px;
  }

  .ip-spinner {
    display: block;
    width: 16px;
    height: 16px;
    border: 2px solid rgba(255, 255, 255, 0.08);
    border-top-color: rgba(255, 255, 255, 0.4);
    border-radius: 50%;
    animation: ip-spin 0.8s linear infinite;
  }

  @keyframes ip-spin { to { transform: rotate(360deg); } }

  .ip-loading-text {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
  }
</style>
