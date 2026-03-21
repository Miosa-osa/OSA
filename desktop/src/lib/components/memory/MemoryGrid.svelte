<script lang="ts">
  import type { MemoryEntry } from '$lib/stores/memory.svelte';
  import MemoryCard from './MemoryCard.svelte';

  // ── Props ────────────────────────────────────────────────────────────────────

  interface Props {
    entries: MemoryEntry[];
    selectedId: string | null;
    loading: boolean;
    totalCount: number;
    narrow?: boolean;
    onSelect: (id: string) => void;
    onDelete: (id: string) => void;
    onAddFirst?: () => void;
    onClearFilters?: () => void;
  }

  let {
    entries,
    selectedId,
    loading,
    totalCount,
    narrow = false,
    onSelect,
    onDelete,
    onAddFirst,
    onClearFilters,
  }: Props = $props();
</script>

<div
  class="mg-panel"
  class:mg-panel--narrow={narrow}
  role="tabpanel"
  aria-label="Memory entries"
>
  {#if loading}
    <div class="mg-status" role="status" aria-live="polite">
      <span class="mg-spinner" aria-hidden="true"></span>
      <span class="mg-status-label">Loading memories...</span>
    </div>

  {:else if entries.length === 0}
    {#if totalCount === 0}
      <div class="mg-empty" role="status">
        <div class="mg-empty-icon" aria-hidden="true">
          <svg width="44" height="44" viewBox="0 0 44 44" fill="none" xmlns="http://www.w3.org/2000/svg">
            <rect x="6" y="6" width="32" height="32" rx="6" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.2"/>
            <path d="M14 22h16M22 14v16" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.35"/>
          </svg>
        </div>
        <p class="mg-empty-title">No memories yet</p>
        <p class="mg-empty-subtitle">Add facts, preferences, context, and instructions for the agent to remember across sessions.</p>
        {#if onAddFirst}
          <button
            class="mg-empty-cta"
            onclick={onAddFirst}
            aria-label="Add first memory entry"
          >
            Add your first memory
          </button>
        {/if}
      </div>
    {:else}
      <div class="mg-empty" role="status">
        <div class="mg-empty-icon" aria-hidden="true">
          <svg width="40" height="40" viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
            <circle cx="18" cy="18" r="11" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.3"/>
            <line x1="26.5" y1="26.5" x2="36" y2="36" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.3"/>
          </svg>
        </div>
        <p class="mg-empty-title">No results</p>
        <p class="mg-empty-subtitle">No memories match your current search or filter.</p>
        {#if onClearFilters}
          <button
            class="mg-empty-cta"
            onclick={onClearFilters}
            aria-label="Clear filters to show all memories"
          >
            Clear filters
          </button>
        {/if}
      </div>
    {/if}

  {:else}
    <div class="mg-grid" role="list" aria-label="Memory entries">
      {#each entries as entry (entry.id)}
        <div role="listitem">
          <MemoryCard
            {entry}
            selected={selectedId === entry.id}
            onSelect={() => onSelect(entry.id)}
            onDelete={onDelete}
          />
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .mg-panel {
    flex: 1;
    overflow-y: auto;
    padding: 0 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
    min-width: 0;
  }

  .mg-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 10px;
  }

  .mg-panel--narrow .mg-grid {
    grid-template-columns: 1fr;
  }

  /* ── Loading ── */

  .mg-status {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 10px;
    min-height: 200px;
    color: var(--text-tertiary);
  }

  .mg-spinner {
    width: 16px;
    height: 16px;
    border: 1.5px solid rgba(255, 255, 255, 0.1);
    border-top-color: rgba(255, 255, 255, 0.5);
    border-radius: 50%;
    animation: mg-spin 0.8s linear infinite;
    flex-shrink: 0;
  }

  @keyframes mg-spin {
    to { transform: rotate(360deg); }
  }

  .mg-status-label {
    font-size: 0.8125rem;
  }

  /* ── Empty states ── */

  .mg-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 320px;
    gap: 10px;
    text-align: center;
    padding: 48px 32px;
  }

  .mg-empty-icon {
    color: rgba(255, 255, 255, 0.1);
    margin-bottom: 4px;
  }

  .mg-empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .mg-empty-subtitle {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    max-width: 300px;
    line-height: 1.5;
  }

  .mg-empty-cta {
    margin-top: 8px;
    padding: 8px 18px;
    border-radius: var(--radius-full);
    border: 1px solid rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-weight: 500;
    transition: background 0.15s, border-color 0.15s, color 0.15s;
  }

  .mg-empty-cta:hover {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }
</style>
