<script lang="ts">
  import type { ProviderGroup } from '$lib/stores/models.svelte';
  import type { Model } from '$lib/api/types';
  import ModelCard from './ModelCard.svelte';

  // ── Props ────────────────────────────────────────────────────────────────────

  interface Props {
    groups: ProviderGroup[];
    loading: boolean;
    switching: string | null;
    query: string;
    onActivate: (model: Model) => void;
  }

  let { groups, loading, switching, query, onActivate }: Props = $props();

  // ── Collapsed state ───────────────────────────────────────────────────────

  let collapsed = $state<Set<string>>(new Set());

  function toggleProvider(slug: string) {
    const next = new Set(collapsed);
    if (next.has(slug)) {
      next.delete(slug);
    } else {
      next.add(slug);
    }
    collapsed = next;
  }
</script>

{#if loading}
  <div class="mgr-loading" aria-label="Loading models" aria-busy="true">
    {#each [1, 2, 3] as _}
      <div class="mgr-skeleton glass-panel">
        <div class="mgr-skel-header"></div>
        <div class="mgr-skel-row"></div>
        <div class="mgr-skel-row mgr-skel-row--short"></div>
        <div class="mgr-skel-row"></div>
      </div>
    {/each}
  </div>

{:else if groups.length === 0}
  <div class="mgr-empty glass-panel">
    <svg class="mgr-empty-icon" width="40" height="40" viewBox="0 0 24 24" fill="none"
         stroke="currentColor" stroke-width="1.5" aria-hidden="true">
      <rect x="2" y="3" width="20" height="14" rx="2"/>
      <path d="M8 21h8m-4-4v4"/>
    </svg>
    {#if query}
      <p class="mgr-empty-title">No models match "{query}"</p>
      <p class="mgr-empty-sub">Try a different search term.</p>
    {:else}
      <p class="mgr-empty-title">No models available</p>
      <p class="mgr-empty-sub">Configure a provider in Settings to get started.</p>
    {/if}
  </div>

{:else}
  <div class="mgr-sections">
    {#each groups as group (group.meta.slug)}
      <section class="mgr-provider glass-panel" aria-label="{group.meta.label} models">

        <button
          class="mgr-provider-header"
          aria-expanded={!collapsed.has(group.meta.slug)}
          aria-controls="mgr-models-{group.meta.slug}"
          onclick={() => toggleProvider(group.meta.slug)}
        >
          <span
            class="mgr-provider-icon"
            style="background: {group.meta.color}20; color: {group.meta.color}; border-color: {group.meta.color}40"
            aria-hidden="true"
          >
            {group.meta.letter}
          </span>

          <span class="mgr-provider-name">{group.meta.label}</span>

          <span class="mgr-count-badge" aria-label="{group.models.length} models">
            {group.models.length}
          </span>

          <span
            class="mgr-avail-dot"
            class:mgr-avail-dot--active={group.available}
            aria-label={group.available ? 'Has active model' : 'No active model'}
          ></span>

          <svg
            class="mgr-chevron"
            class:mgr-chevron--collapsed={collapsed.has(group.meta.slug)}
            width="14" height="14" viewBox="0 0 24 24" fill="none"
            stroke="currentColor" stroke-width="2" aria-hidden="true"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7"/>
          </svg>
        </button>

        {#if !collapsed.has(group.meta.slug)}
          <ul
            class="mgr-model-list"
            id="mgr-models-{group.meta.slug}"
            role="list"
          >
            {#each group.models as model (model.name)}
              <ModelCard
                {model}
                {switching}
                {onActivate}
              />
            {/each}
          </ul>
        {/if}
      </section>
    {/each}
  </div>
{/if}

<style>
  /* ── Loading skeletons ── */

  .mgr-loading {
    display: flex;
    flex-direction: column;
    gap: 8px;
    overflow: hidden;
  }

  .mgr-skeleton {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .mgr-skel-header {
    height: 20px;
    width: 160px;
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.06);
    animation: mgr-shimmer 1.4s ease-in-out infinite;
  }

  .mgr-skel-row {
    height: 16px;
    width: 100%;
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.04);
    animation: mgr-shimmer 1.4s ease-in-out infinite 0.1s;
  }

  .mgr-skel-row--short {
    width: 60%;
    animation-delay: 0.2s;
  }

  /* ── Empty ── */

  .mgr-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 64px 24px;
    text-align: center;
  }

  .mgr-empty-icon {
    color: var(--text-tertiary);
    margin-bottom: 4px;
  }

  .mgr-empty-title {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-secondary);
  }

  .mgr-empty-sub {
    font-size: 13px;
    color: var(--text-tertiary);
  }

  /* ── Sections container ── */

  .mgr-sections {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding-right: 2px;
    padding-bottom: 24px;
  }

  /* ── Provider section ── */

  .mgr-provider {
    padding: 0;
    overflow: hidden;
    transition: border-color 0.15s ease;
  }

  .mgr-provider-header {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 12px 16px;
    background: transparent;
    border: none;
    color: var(--text-primary);
    cursor: pointer;
    text-align: left;
    transition: background 0.15s ease;
  }

  .mgr-provider-header:hover {
    background: rgba(255, 255, 255, 0.03);
  }

  .mgr-provider-header:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: -2px;
  }

  .mgr-provider-icon {
    width: 28px;
    height: 28px;
    border-radius: var(--radius-sm);
    border: 1px solid;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 13px;
    font-weight: 700;
    flex-shrink: 0;
    letter-spacing: 0;
  }

  .mgr-provider-name {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
    flex: 1;
  }

  .mgr-count-badge {
    font-size: 11px;
    font-weight: 500;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-full);
    padding: 1px 7px;
  }

  .mgr-avail-dot {
    width: 7px;
    height: 7px;
    border-radius: 9999px;
    background: rgba(255, 255, 255, 0.15);
    flex-shrink: 0;
  }

  .mgr-avail-dot--active {
    background: var(--accent-success);
  }

  .mgr-chevron {
    color: var(--text-tertiary);
    flex-shrink: 0;
    transition: transform 0.2s ease;
  }

  .mgr-chevron--collapsed {
    transform: rotate(-90deg);
  }

  /* ── Model list ── */

  .mgr-model-list {
    list-style: none;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
    padding: 0;
    margin: 0;
  }

  /* ── Keyframes ── */

  @keyframes mgr-shimmer {
    0%, 100% { opacity: 0.6; }
    50%       { opacity: 1; }
  }
</style>
