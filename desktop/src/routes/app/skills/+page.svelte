<script lang="ts">
  import { onMount } from 'svelte';
  import { skillsStore } from '$lib/stores/skills.svelte';
  import SkillsGrid from '$lib/components/skills/SkillsGrid.svelte';
  import SkillDetail from '$lib/components/skills/SkillDetail.svelte';
  import PageShell from '$lib/components/layout/PageShell.svelte';

  let selectedSkillId = $state<string | null>(null);

  onMount(() => {
    skillsStore.fetchSkills();
  });

  function handleToggle(id: string) {
    skillsStore.toggle(id);
  }

  function handleBulkAction(action: 'enable' | 'disable') {
    const ids = skillsStore.filtered.map((s) => s.id);
    if (ids.length === 0) return;
    if (action === 'enable') skillsStore.bulkEnable(ids);
    else skillsStore.bulkDisable(ids);
  }

  let searchInput = $state('');
  let searchTimer: ReturnType<typeof setTimeout> | null = null;

  function handleSearch(value: string) {
    searchInput = value;
    if (searchTimer) clearTimeout(searchTimer);
    searchTimer = setTimeout(() => skillsStore.setSearch(value), 150);
  }
</script>

<PageShell title="Skills">
  {#snippet actions()}
    <!-- Stats pill -->
    <div class="skl-stats-bar" role="status" aria-label="Skills statistics">
      <span class="skl-stat-value">{skillsStore.enabledCount}</span>
      <span class="skl-stat-label">enabled</span>
      <span class="skl-stat-divider" aria-hidden="true"></span>
      <span class="skl-stat-value">{skillsStore.totalCount}</span>
      <span class="skl-stat-label">total</span>
      {#if skillsStore.loading}
        <span class="skl-loading-spinner" aria-label="Loading"></span>
      {/if}
    </div>

    <!-- Search -->
    <div class="skl-search-wrapper">
      <svg class="skl-search-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
        <circle cx="11" cy="11" r="8" />
        <line x1="21" y1="21" x2="16.65" y2="16.65" />
      </svg>
      <input
        type="search"
        class="skl-search-input"
        placeholder="Search skills..."
        value={searchInput}
        oninput={(e) => handleSearch(e.currentTarget.value)}
        aria-label="Search skills"
      />
    </div>

    <!-- Bulk actions -->
    <div class="skl-bulk-actions">
      <button
        class="skl-bulk-btn"
        onclick={() => handleBulkAction('enable')}
        aria-label="Enable all visible skills"
      >
        Enable visible
      </button>
      <button
        class="skl-bulk-btn skl-bulk-btn--muted"
        onclick={() => handleBulkAction('disable')}
        aria-label="Disable all visible skills"
      >
        Disable visible
      </button>
    </div>
  {/snippet}

  {#snippet tabs()}
    {#each skillsStore.allCategories as cat (cat.name)}
      <button
        class="skl-tab"
        class:skl-tab--active={skillsStore.activeCategory === cat.name}
        onclick={() => skillsStore.setCategory(cat.name)}
        role="tab"
        aria-selected={skillsStore.activeCategory === cat.name}
      >
        {cat.label}
        <span class="skl-tab-count">{cat.count}</span>
      </button>
    {/each}
  {/snippet}

  {#if skillsStore.error}
    <div class="skl-status-banner" role="status">
      <span class="skl-banner-dot"></span>
      <span class="skl-banner-text">Failed to load skills</span>
      <button class="skl-banner-btn" onclick={() => skillsStore.fetchSkills()}>
        Retry
      </button>
    </div>
  {/if}

  <SkillsGrid
    skills={skillsStore.filtered}
    onToggle={handleToggle}
    onSelect={(id) => { selectedSkillId = id; }}
  />
</PageShell>

{#if selectedSkillId}
  <SkillDetail
    skillId={selectedSkillId}
    onClose={() => { selectedSkillId = null; }}
    onToggle={(id) => { handleToggle(id); }}
  />
{/if}

<style>
  /* ── Stats pill ── */

  .skl-stats-bar {
    display: flex;
    align-items: center;
    gap: 6px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    padding: 4px 12px;
  }

  .skl-stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  .skl-stat-label {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .skl-stat-divider {
    width: 1px;
    height: 12px;
    background: rgba(255, 255, 255, 0.08);
    margin: 0 4px;
  }

  .skl-loading-spinner {
    width: 12px;
    height: 12px;
    border: 1.5px solid rgba(255, 255, 255, 0.1);
    border-top-color: rgba(255, 255, 255, 0.5);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    margin-left: 4px;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* ── Search ── */

  .skl-search-wrapper {
    position: relative;
    display: flex;
    align-items: center;
  }

  .skl-search-icon {
    position: absolute;
    left: 10px;
    color: var(--text-muted);
    pointer-events: none;
  }

  .skl-search-input {
    width: 220px;
    padding: 6px 10px 6px 32px;
    border-radius: var(--radius-sm);
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: rgba(255, 255, 255, 0.04);
    color: var(--text-primary);
    font-size: 0.8125rem;
    outline: none;
    transition: border-color 0.15s;
  }

  .skl-search-input::placeholder {
    color: var(--text-muted);
  }

  .skl-search-input:focus {
    border-color: var(--border-focus);
  }

  /* ── Bulk actions ── */

  .skl-bulk-actions {
    display: flex;
    gap: 6px;
  }

  .skl-bulk-btn {
    padding: 5px 12px;
    border-radius: var(--radius-sm);
    border: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
  }

  .skl-bulk-btn:hover {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text-primary);
  }

  .skl-bulk-btn--muted {
    color: var(--text-tertiary);
    border-color: rgba(255, 255, 255, 0.06);
  }

  /* ── Category tabs (rendered inside ps-tabs-strip) ── */

  .skl-tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 14px;
    border-radius: var(--radius-sm);
    border: none;
    background: none;
    color: var(--text-tertiary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
    white-space: nowrap;
  }

  .skl-tab:hover {
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
  }

  .skl-tab--active {
    background: rgba(59, 130, 246, 0.1);
    color: var(--text-primary);
  }

  .skl-tab-count {
    font-size: 0.6875rem;
    font-variant-numeric: tabular-nums;
    color: var(--text-muted);
    min-width: 14px;
    text-align: center;
  }

  .skl-tab--active .skl-tab-count {
    color: var(--accent-primary);
  }

  /* ── Error banner ── */

  .skl-status-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    margin-bottom: 16px;
  }

  .skl-banner-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .skl-banner-text {
    color: var(--text-secondary);
  }

  .skl-banner-btn {
    margin-left: auto;
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

  .skl-banner-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    color: var(--text-primary);
  }
</style>
