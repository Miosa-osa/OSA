<script lang="ts">
  import { onMount } from 'svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import type { WorkspaceConfig } from '$lib/api/types';

  let config = $state<WorkspaceConfig | null>(null);
  let loadingConfig = $state(false);

  const active = $derived(workspaceStore.activeWorkspace);
  const workspaces = $derived(workspaceStore.workspaces);

  onMount(async () => {
    if (active?.id) {
      loadingConfig = true;
      try {
        config = await workspaceStore.fetchWorkspaceConfig(active.id);
      } catch {
        // handled by store toast
      } finally {
        loadingConfig = false;
      }
    }
  });

  async function openInFinder() {
    if (!active?.directory) return;
    try {
      const { open } = await import('@tauri-apps/plugin-shell');
      await open(active.directory);
    } catch {
      // Tauri not available
    }
  }
</script>

<section class="swk-section">
  <h2 class="swk-section-title">Canopy Workspace</h2>
  <p class="swk-section-desc">Active workspace configuration and Canopy protocol status.</p>

  {#if active}
    <div class="swk-settings-group">
      <div class="swk-settings-item">
        <div class="swk-item-meta">
          <span class="swk-item-label">Workspace</span>
          <span class="swk-item-hint">Currently active Canopy workspace.</span>
        </div>
        <span class="swk-field-readonly">{active.name}</span>
      </div>

      <div class="swk-item-divider"></div>

      <div class="swk-settings-item">
        <div class="swk-item-meta">
          <span class="swk-item-label">Path</span>
          <span class="swk-item-hint">Directory containing the .canopy/ folder.</span>
        </div>
        <div class="swk-path-row">
          <code class="swk-path-value">{active.directory ?? '—'}</code>
          {#if active.directory}
            <button type="button" class="swk-btn-sm" onclick={openInFinder}>
              Open
            </button>
          {/if}
        </div>
      </div>

      <div class="swk-item-divider"></div>

      <div class="swk-settings-item">
        <span class="swk-item-label">Agents</span>
        <span class="swk-field-readonly">{active.agent_count ?? 0} defined</span>
      </div>

      <div class="swk-item-divider"></div>

      <div class="swk-settings-item">
        <span class="swk-item-label">Skills</span>
        <span class="swk-field-readonly">{active.skill_count ?? 0} available</span>
      </div>

      <div class="swk-item-divider"></div>

      <div class="swk-settings-item">
        <span class="swk-item-label">Canopy files</span>
        <span class="swk-field-readonly">
          {#if loadingConfig}
            Loading...
          {:else if config}
            {config.has_system ? 'SYSTEM.md' : ''}{config.has_system && config.has_company ? ' · ' : ''}{config.has_company ? 'COMPANY.md' : ''}{!config.has_system && !config.has_company ? 'None found' : ''}
          {:else}
            —
          {/if}
        </span>
      </div>
    </div>

    {#if config?.system}
      <div class="swk-preview-block">
        <h3 class="swk-preview-title">SYSTEM.md</h3>
        <pre class="swk-preview-content">{config.system}</pre>
      </div>
    {/if}
  {:else}
    <div class="swk-empty">
      <p class="swk-empty-text">No active workspace. Create or select a workspace from the sidebar.</p>
      <p class="swk-empty-hint">Canopy workspaces define your agents, skills, and knowledge for each project.</p>
    </div>
  {/if}

  <div class="swk-info-block">
    <p class="swk-info-title">About Canopy</p>
    <p class="swk-info-desc">
      Canopy is the open workspace protocol for AI agents. Each workspace contains a <code>.canopy/</code> directory
      with agent definitions, skills, and reference knowledge — making your AI environment portable and version-controlled.
    </p>
  </div>

  {#if workspaces.length > 1}
    <div class="swk-all-workspaces">
      <h3 class="swk-sub-title">All workspaces ({workspaces.length})</h3>
      <div class="swk-ws-list">
        {#each workspaces as ws (ws.id)}
          <div class="swk-ws-item" class:swk-ws-item--active={ws.id === active?.id}>
            <span class="swk-ws-name">{ws.name}</span>
            <span class="swk-ws-path">{ws.directory ?? ''}</span>
            {#if ws.id === active?.id}
              <span class="swk-ws-badge">Active</span>
            {/if}
          </div>
        {/each}
      </div>
    </div>
  {/if}
</section>

<style>
  .swk-section { max-width: 560px; }

  .swk-section-title {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
    margin: 0 0 4px;
  }

  .swk-section-desc {
    font-size: 13px;
    color: var(--text-tertiary);
    margin: 0 0 24px;
  }

  .swk-settings-group {
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md, 10px);
    padding: 4px 0;
    margin-bottom: 24px;
  }

  .swk-settings-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    min-height: 44px;
  }

  .swk-item-meta {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .swk-item-label {
    font-size: 13px;
    font-weight: 500;
    color: var(--text-primary);
  }

  .swk-item-hint {
    font-size: 11px;
    color: var(--text-tertiary);
  }

  .swk-item-divider {
    height: 1px;
    background: rgba(255, 255, 255, 0.04);
    margin: 0 16px;
  }

  .swk-field-readonly {
    font-size: 13px;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
    flex-shrink: 0;
  }

  .swk-path-row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }

  .swk-path-value {
    font-size: 12px;
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.04);
    padding: 3px 8px;
    border-radius: 4px;
    max-width: 220px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .swk-btn-sm {
    font-size: 11px;
    font-weight: 500;
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 5px;
    padding: 3px 10px;
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease;
  }

  .swk-btn-sm:hover {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text-primary);
  }

  .swk-preview-block {
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md, 10px);
    padding: 16px;
    margin-bottom: 24px;
  }

  .swk-preview-title {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    margin: 0 0 8px;
  }

  .swk-preview-content {
    font-size: 12px;
    line-height: 1.6;
    color: var(--text-secondary);
    white-space: pre-wrap;
    word-break: break-word;
    max-height: 200px;
    overflow-y: auto;
    margin: 0;
  }

  .swk-empty {
    background: rgba(255, 255, 255, 0.02);
    border: 1px dashed rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md, 10px);
    padding: 32px 24px;
    text-align: center;
    margin-bottom: 24px;
  }

  .swk-empty-text {
    font-size: 14px;
    color: var(--text-secondary);
    margin: 0 0 6px;
  }

  .swk-empty-hint {
    font-size: 12px;
    color: var(--text-tertiary);
    margin: 0;
  }

  .swk-info-block {
    background: rgba(139, 92, 246, 0.06);
    border: 1px solid rgba(139, 92, 246, 0.15);
    border-radius: var(--radius-md, 10px);
    padding: 16px;
    margin-bottom: 24px;
  }

  .swk-info-title {
    font-size: 13px;
    font-weight: 600;
    color: rgba(167, 139, 250, 0.9);
    margin: 0 0 6px;
  }

  .swk-info-desc {
    font-size: 12px;
    line-height: 1.6;
    color: var(--text-secondary);
    margin: 0;
  }

  .swk-info-desc code {
    font-size: 11px;
    background: rgba(255, 255, 255, 0.06);
    padding: 1px 5px;
    border-radius: 3px;
    color: rgba(167, 139, 250, 0.8);
  }

  .swk-all-workspaces { margin-top: 8px; }

  .swk-sub-title {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-secondary);
    margin: 0 0 12px;
  }

  .swk-ws-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .swk-ws-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 14px;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-sm, 6px);
  }

  .swk-ws-item--active {
    border-color: rgba(139, 92, 246, 0.2);
    background: rgba(139, 92, 246, 0.04);
  }

  .swk-ws-name {
    font-size: 13px;
    font-weight: 500;
    color: var(--text-primary);
  }

  .swk-ws-path {
    font-size: 11px;
    color: var(--text-tertiary);
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .swk-ws-badge {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: rgba(167, 139, 250, 0.9);
    background: rgba(139, 92, 246, 0.12);
    padding: 2px 8px;
    border-radius: 4px;
    flex-shrink: 0;
  }
</style>
