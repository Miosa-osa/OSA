<script lang="ts">
  import type { Snippet } from 'svelte';

  interface Props {
    title: string;
    subtitle?: string;
    children: Snippet;
    actions?: Snippet;
    tabs?: Snippet;
    banner?: Snippet;
  }

  let { title, subtitle, children, actions, tabs, banner }: Props = $props();
</script>

<div class="ps-page">
  <header class="ps-header">
    <div class="ps-header-left">
      <div class="ps-title-group">
        <h1 class="ps-title">{title}</h1>
        {#if subtitle}
          <p class="ps-subtitle">{subtitle}</p>
        {/if}
      </div>
    </div>

    {#if actions}
      <div class="ps-header-actions">
        {@render actions()}
      </div>
    {/if}
  </header>

  {#if tabs}
    <div class="ps-tabs-strip">
      {@render tabs()}
    </div>
  {/if}

  <main class="ps-content">
    {#if banner}
      <div class="ps-banner" role="status">
        {@render banner()}
      </div>
    {/if}

    {@render children()}
  </main>
</div>

<style>
  .ps-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  /* ── Header ── */

  .ps-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 24px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
    gap: 16px;
    flex-wrap: wrap;
  }

  .ps-header-left {
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
  }

  .ps-title-group {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .ps-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
  }

  .ps-subtitle {
    font-size: 0.75rem;
    color: var(--text-tertiary);
    line-height: 1;
  }

  .ps-header-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }

  /* ── Tabs strip ── */

  .ps-tabs-strip {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 8px 24px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    overflow-x: auto;
    scrollbar-width: none;
    flex-shrink: 0;
  }

  .ps-tabs-strip::-webkit-scrollbar {
    display: none;
  }

  /* ── Scrollable content area ── */

  .ps-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  /* ── Status banner ── */

  .ps-banner {
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
</style>
