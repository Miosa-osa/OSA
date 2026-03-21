<!-- src/routes/app/models/+page.svelte -->
<script lang="ts">
  import { onMount } from 'svelte';
  import { modelsStore } from '$lib/stores/models.svelte';
  import { restartBackend } from '$lib/utils/backend';
  import type { Model } from '$lib/api/types';
  import ModelGrid from '$lib/components/models/ModelGrid.svelte';
  import ModelSwitcher from '$lib/components/models/ModelSwitcher.svelte';

  // ── State ──────────────────────────────────────────────────────────────────

  let query = $state('');

  // ── Derived ────────────────────────────────────────────────────────────────

  let groups = $derived(modelsStore.searchFiltered(query));

  // ── Handlers ───────────────────────────────────────────────────────────────

  async function handleActivate(model: Model) {
    if (model.active || modelsStore.switching === model.name) return;
    await modelsStore.activateModel(model.name);
  }

  onMount(() => {
    modelsStore.fetchModels();
  });
</script>

<svelte:head>
  <title>Models — OSA</title>
</svelte:head>

<div class="mp-root" aria-label="Model browser">

  <!-- ── Header ── -->
  <header class="mp-header">
    <div class="mp-header-left">
      <h1 class="mp-title">Models</h1>
      <ModelSwitcher
        current={modelsStore.current}
        currentLabel={modelsStore.currentLabel}
        switching={modelsStore.switching}
        switchError={modelsStore.switchError}
      />
    </div>

    <div class="mp-search-wrap">
      <svg class="mp-search-icon" width="14" height="14" viewBox="0 0 24 24" fill="none"
           stroke="currentColor" stroke-width="2" aria-hidden="true">
        <circle cx="11" cy="11" r="8"/>
        <path stroke-linecap="round" d="M21 21l-4.35-4.35"/>
      </svg>
      <input
        class="mp-search glass-input"
        type="search"
        placeholder="Search models..."
        aria-label="Search models"
        bind:value={query}
      />
    </div>
  </header>

  <!-- ── Recommendation banner ── -->
  <div class="mp-recommend" role="note">
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
      <circle cx="12" cy="12" r="10"/>
      <line x1="12" y1="16" x2="12" y2="12"/>
      <line x1="12" y1="8" x2="12.01" y2="8"/>
    </svg>
    <span>For best agent performance, use models with <strong>tool use</strong>, <strong>code generation</strong>, and <strong>long context</strong> (32K+). Recommended: Claude Opus 4.6 / Sonnet 4.6, GPT-4.1, Llama 3.3 70B, o3/o4-mini for reasoning. Configure API keys in Settings to unlock cloud models.</span>
  </div>

  <!-- ── Backend error banner ── -->
  {#if modelsStore.error}
    <div class="mp-status-banner" role="status">
      <span class="mp-status-dot-indicator"></span>
      <span class="mp-status-text">Backend offline</span>
      <span class="mp-status-hint">Start OSA backend on port 9089</span>
      <button
        class="mp-restart-btn"
        onclick={() => { restartBackend().then(() => modelsStore.fetchModels()).catch(() => {}); }}
        aria-label="Restart backend"
      >
        Restart
      </button>
      <button
        class="mp-restart-btn"
        onclick={() => modelsStore.fetchModels()}
        aria-label="Retry"
      >
        Retry
      </button>
    </div>
  {/if}

  <!-- ── Model grid ── -->
  <ModelGrid
    {groups}
    loading={modelsStore.loading}
    switching={modelsStore.switching}
    {query}
    onActivate={handleActivate}
  />

</div>

<style>
  .mp-root {
    display: flex;
    flex-direction: column;
    height: 100%;
    padding: 24px;
    gap: 16px;
    overflow-x: hidden;
    overflow-y: auto;
  }

  /* ── Header ── */

  .mp-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    flex-shrink: 0;
  }

  .mp-header-left {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
  }

  .mp-title {
    font-size: 20px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
    flex-shrink: 0;
  }

  /* ── Search ── */

  .mp-search-wrap {
    position: relative;
    width: 220px;
    flex-shrink: 0;
  }

  .mp-search-icon {
    position: absolute;
    left: 12px;
    top: 50%;
    transform: translateY(-50%);
    color: var(--text-tertiary);
    pointer-events: none;
  }

  .mp-search {
    padding-left: 34px;
  }

  /* ── Recommendation banner ── */

  .mp-recommend {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    padding: 10px 16px;
    margin: 0 16px 8px;
    font-size: 0.75rem;
    line-height: 1.5;
    color: rgba(255, 255, 255, 0.45);
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 10px;
    flex-shrink: 0;
  }

  .mp-recommend svg {
    flex-shrink: 0;
    margin-top: 1px;
    color: rgba(255, 255, 255, 0.3);
  }

  .mp-recommend strong {
    color: rgba(255, 255, 255, 0.65);
    font-weight: 600;
  }

  /* ── Status banner ── */

  .mp-status-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    flex-shrink: 0;
  }

  .mp-status-dot-indicator {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .mp-status-text {
    color: var(--text-secondary);
  }

  .mp-status-hint {
    margin-left: auto;
    color: var(--text-muted);
  }

  .mp-restart-btn {
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .mp-restart-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }
</style>
