<script lang="ts">
  import { onMount } from 'svelte';
  import { memoryStore, type MemoryCategory, type SortMode } from '$lib/stores/memory.svelte';
  import MemoryForm from '$lib/components/memory/MemoryForm.svelte';
  import MemoryGrid from '$lib/components/memory/MemoryGrid.svelte';
  import MemoryDetail from '$lib/components/memory/MemoryDetail.svelte';

  // ── Tab / sort config ─────────────────────────────────────────────────────

  type TabId = 'all' | MemoryCategory;

  const TABS: { id: TabId; label: string }[] = [
    { id: 'all',         label: 'All' },
    { id: 'fact',        label: 'Facts' },
    { id: 'preference',  label: 'Preferences' },
    { id: 'context',     label: 'Context' },
    { id: 'instruction', label: 'Instructions' },
    { id: 'other',       label: 'Other' },
  ];

  const SORT_OPTIONS: { value: SortMode; label: string }[] = [
    { value: 'relevance', label: 'By Relevance' },
    { value: 'updated',   label: 'Recently Updated' },
    { value: 'key',       label: 'By Key (A–Z)' },
  ];

  function tabCount(id: TabId): number {
    if (id === 'all') return memoryStore.totalCount;
    return memoryStore.categoryCounts[id] ?? 0;
  }

  // ── Add form ──────────────────────────────────────────────────────────────

  let showAddForm = $state(false);

  async function handleAdd(entry: { key: string; value: string; category: MemoryCategory; tags: string[] }) {
    await memoryStore.addMemory(entry);
    showAddForm = false;
  }

  // ── CRUD ──────────────────────────────────────────────────────────────────

  async function handleUpdate(
    id: string,
    patch: Partial<Omit<import('$lib/stores/memory.svelte').MemoryEntry, 'id' | 'created_at'>>,
  ) {
    await memoryStore.updateMemory(id, patch);
  }

  async function handleDelete(id: string) {
    await memoryStore.deleteMemory(id);
  }

  // ── Keyboard shortcuts ────────────────────────────────────────────────────

  function handlePageKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      if (showAddForm) {
        showAddForm = false;
      } else if (memoryStore.searchQuery) {
        memoryStore.setSearch('');
      } else {
        memoryStore.select(null);
      }
    }
  }

  onMount(() => {
    memoryStore.fetchMemories();
  });
</script>

<svelte:window onkeydown={handlePageKeydown} />

<div class="memory-page">

  <!-- ── Header ── -->
  <header class="page-header">
    <div class="header-left">
      <h1 class="page-title">Memory Vault</h1>
      <p class="page-subtitle">Persistent knowledge and context</p>
    </div>

    <div class="header-right">
      <div class="sort-wrapper">
        <select
          class="sort-select"
          value={memoryStore.sortBy}
          onchange={(e) => memoryStore.setSort((e.currentTarget as HTMLSelectElement).value as SortMode)}
          aria-label="Sort memory entries"
        >
          {#each SORT_OPTIONS as opt (opt.value)}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
        <svg class="sort-chevron" width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
          <polyline points="2,3.5 5.5,7 9,3.5"/>
        </svg>
      </div>

      <button
        class="add-btn"
        class:add-btn--active={showAddForm}
        onclick={() => { showAddForm = !showAddForm; }}
        aria-expanded={showAddForm}
        aria-controls="add-memory-form"
        aria-label="Add new memory entry"
      >
        <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true">
          <line x1="6.5" y1="1" x2="6.5" y2="12"/>
          <line x1="1" y1="6.5" x2="12" y2="6.5"/>
        </svg>
        Add Memory
      </button>
    </div>
  </header>

  <!-- ── Add form ── -->
  {#if showAddForm}
    <MemoryForm
      onSubmit={handleAdd}
      onCancel={() => { showAddForm = false; }}
    />
  {/if}

  <!-- ── Search ── -->
  <div class="search-row">
    <div class="search-wrap">
      <svg class="search-icon" width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
        <circle cx="6" cy="6" r="4.5"/>
        <line x1="9.5" y1="9.5" x2="13" y2="13"/>
      </svg>
      <input
        class="glass-input search-input"
        type="search"
        placeholder="Search keys, values, or tags..."
        value={memoryStore.searchQuery}
        oninput={(e) => memoryStore.setSearch((e.currentTarget as HTMLInputElement).value)}
        aria-label="Search memory entries"
        spellcheck="false"
      />
      {#if memoryStore.searchQuery}
        <button
          class="search-clear"
          onclick={() => memoryStore.setSearch('')}
          aria-label="Clear search"
        >
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true">
            <line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/>
            <line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/>
          </svg>
        </button>
      {/if}
    </div>
  </div>

  <!-- ── Category tabs ── -->
  <div class="tab-row" role="tablist" aria-label="Filter by category">
    {#each TABS as tab (tab.id)}
      <button
        class="tab"
        class:tab--active={memoryStore.filterCategory === tab.id}
        role="tab"
        aria-selected={memoryStore.filterCategory === tab.id}
        onclick={() => memoryStore.setFilter(tab.id)}
        aria-label="Show {tab.label} ({tabCount(tab.id)})"
      >
        {tab.label}
        <span class="tab-count">{tabCount(tab.id)}</span>
      </button>
    {/each}
  </div>

  <!-- ── Master-detail body ── -->
  <div class="body-row">
    <MemoryGrid
      entries={memoryStore.filtered}
      selectedId={memoryStore.selectedId}
      loading={memoryStore.loading}
      totalCount={memoryStore.totalCount}
      narrow={memoryStore.selected !== null}
      onSelect={(id) => memoryStore.select(id)}
      onDelete={(id) => void memoryStore.deleteMemory(id)}
      onAddFirst={() => { showAddForm = true; }}
      onClearFilters={() => { memoryStore.setSearch(''); memoryStore.setFilter('all'); }}
    />

    {#if memoryStore.selected !== null}
      <MemoryDetail
        entry={memoryStore.selected}
        onClose={() => memoryStore.select(null)}
        onUpdate={handleUpdate}
        onDelete={handleDelete}
      />
    {/if}
  </div>

  <!-- ── Error banner ── -->
  {#if memoryStore.error}
    <div class="error-banner" role="alert">
      <span class="error-dot" aria-hidden="true"></span>
      <span class="error-text">{memoryStore.error}</span>
      <button
        class="error-dismiss"
        onclick={() => memoryStore.clearError()}
        aria-label="Dismiss error"
      >
        Dismiss
      </button>
    </div>
  {/if}
</div>

<style>
  .memory-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  /* ── Header ── */

  .page-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 24px 0;
    flex-shrink: 0;
    gap: 16px;
    flex-wrap: wrap;
  }

  .header-left {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .page-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
    line-height: 1.2;
  }

  .page-subtitle {
    font-size: 0.75rem;
    color: var(--text-tertiary);
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  /* ── Sort dropdown ── */

  .sort-wrapper {
    position: relative;
    display: flex;
    align-items: center;
  }

  .sort-select {
    appearance: none;
    -webkit-appearance: none;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md);
    padding: 6px 28px 6px 10px;
    font-size: 0.75rem;
    color: var(--text-secondary);
    cursor: pointer;
    transition: border-color 0.15s;
    outline: none;
  }

  .sort-select:hover {
    border-color: rgba(255, 255, 255, 0.15);
    color: var(--text-primary);
  }

  .sort-select option {
    background: #1e1e1e;
    color: #fff;
  }

  .sort-chevron {
    position: absolute;
    right: 8px;
    pointer-events: none;
    color: var(--text-tertiary);
  }

  /* ── Add button ── */

  .add-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-md);
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-primary);
    transition: background 0.15s, border-color 0.15s;
  }

  .add-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
  }

  .add-btn--active {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.2);
  }

  /* ── Search bar ── */

  .search-row {
    padding: 16px 24px 0;
    flex-shrink: 0;
  }

  .search-wrap {
    position: relative;
    display: flex;
    align-items: center;
  }

  .search-icon {
    position: absolute;
    left: 12px;
    color: var(--text-tertiary);
    pointer-events: none;
  }

  .search-input {
    padding-left: 36px !important;
    font-size: 0.875rem;
  }

  .search-clear {
    position: absolute;
    right: 10px;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    border-radius: var(--radius-xs);
    border: none;
    background: none;
    color: var(--text-tertiary);
    transition: color 0.12s;
  }

  .search-clear:hover {
    color: var(--text-secondary);
  }

  /* ── Category tabs ── */

  .tab-row {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 12px 24px 0;
    flex-shrink: 0;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .tab-row::-webkit-scrollbar {
    display: none;
  }

  .tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 12px;
    border-radius: var(--radius-full);
    border: 1px solid transparent;
    background: none;
    color: var(--text-tertiary);
    font-size: 0.75rem;
    font-weight: 500;
    white-space: nowrap;
    transition: background 0.12s, border-color 0.12s, color 0.12s;
  }

  .tab:hover:not(.tab--active) {
    background: rgba(255, 255, 255, 0.04);
    color: var(--text-secondary);
  }

  .tab--active {
    background: rgba(255, 255, 255, 0.08);
    border-color: rgba(255, 255, 255, 0.12);
    color: var(--text-primary);
  }

  .tab-count {
    font-size: 0.625rem;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    background: rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-full);
    padding: 1px 6px;
    color: var(--text-muted);
    min-width: 18px;
    text-align: center;
  }

  .tab--active .tab-count {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text-tertiary);
  }

  /* ── Body ── */

  .body-row {
    flex: 1;
    display: flex;
    overflow: hidden;
    margin-top: 12px;
  }

  /* ── Error banner ── */

  .error-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 20px;
    background: rgba(239, 68, 68, 0.06);
    border-top: 1px solid rgba(239, 68, 68, 0.15);
    font-size: 0.75rem;
    color: rgba(239, 68, 68, 0.8);
    flex-shrink: 0;
  }

  .error-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(239, 68, 68, 0.7);
    flex-shrink: 0;
  }

  .error-text {
    flex: 1;
    min-width: 0;
  }

  .error-dismiss {
    flex-shrink: 0;
    padding: 3px 10px;
    background: rgba(239, 68, 68, 0.1);
    border: 1px solid rgba(239, 68, 68, 0.2);
    border-radius: var(--radius-full);
    color: rgba(239, 68, 68, 0.8);
    font-size: 0.6875rem;
    font-weight: 500;
    transition: background 0.12s;
  }

  .error-dismiss:hover {
    background: rgba(239, 68, 68, 0.18);
  }
</style>
