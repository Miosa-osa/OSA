<script lang="ts">
  import { fly, fade } from 'svelte/transition';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import type { Workspace } from '$lib/api/types';
  import CreateWorkspaceModal from './CreateWorkspaceModal.svelte';

  interface Props {
    isCollapsed: boolean;
  }

  let { isCollapsed }: Props = $props();

  let dropdownOpen = $state(false);
  let showCreateModal = $state(false);
  let tooltipVisible = $state(false);
  let containerEl = $state<HTMLDivElement | null>(null);

  function toggleDropdown() {
    dropdownOpen = !dropdownOpen;
  }

  function closeDropdown() {
    dropdownOpen = false;
  }

  async function handleSwitch(workspace: Workspace) {
    if (workspace.id === workspaceStore.activeId) {
      closeDropdown();
      return;
    }
    await workspaceStore.switchWorkspace(workspace.id);
    closeDropdown();
  }

  function handleCreateClick() {
    dropdownOpen = false;
    showCreateModal = true;
  }

  function handleCreated(workspace: Workspace) {
    showCreateModal = false;
    void workspaceStore.switchWorkspace(workspace.id);
  }

  // Close on outside click
  function handleWindowClick(e: MouseEvent) {
    if (!dropdownOpen) return;
    if (containerEl && !containerEl.contains(e.target as Node)) {
      closeDropdown();
    }
  }

  $effect(() => {
    window.addEventListener('click', handleWindowClick);
    return () => window.removeEventListener('click', handleWindowClick);
  });

  const activeWorkspaceName = $derived(
    workspaceStore.activeWorkspace?.name ?? 'No Workspace'
  );

  const activeWorkspaces = $derived(
    workspaceStore.workspaces.filter((w) => w.status === 'active')
  );
</script>

<div class="ws-root" bind:this={containerEl}>
  <!-- Trigger button -->
  <button
    class="ws-trigger"
    class:ws-trigger--collapsed={isCollapsed}
    onclick={toggleDropdown}
    aria-haspopup="listbox"
    aria-expanded={dropdownOpen}
    aria-label={isCollapsed ? `Active workspace: ${activeWorkspaceName}` : undefined}
    onmouseenter={() => { if (isCollapsed) tooltipVisible = true; }}
    onmouseleave={() => { tooltipVisible = false; }}
  >
    <!-- Folder icon -->
    <span class="ws-icon" aria-hidden="true">
      <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" width="16" height="16">
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="1.5"
          d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z"
        />
      </svg>
    </span>

    {#if !isCollapsed}
      <span class="ws-name-group" transition:fade={{ duration: 150 }}>
        <span class="ws-name">{activeWorkspaceName}</span>
        <span class="ws-canopy-label">Canopy Workspace</span>
      </span>
      <span class="ws-chevron" class:ws-chevron--open={dropdownOpen} aria-hidden="true">
        <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" width="12" height="12">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </span>
    {/if}
  </button>

  <!-- Collapsed tooltip -->
  {#if isCollapsed && tooltipVisible}
    <div class="ws-tooltip" transition:fly={{ x: -6, duration: 100 }} role="tooltip">
      {activeWorkspaceName}
    </div>
  {/if}

  <!-- Dropdown panel -->
  {#if dropdownOpen}
    <div
      class="ws-dropdown"
      class:ws-dropdown--collapsed={isCollapsed}
      transition:fly={{ y: -4, duration: 150 }}
      role="listbox"
      aria-label="Switch workspace"
    >
      <div class="ws-dropdown-header">
        <span class="ws-dropdown-title">Workspaces</span>
        {#if workspaceStore.loading}
          <span class="ws-loading-dot" aria-hidden="true"></span>
        {/if}
      </div>

      <div class="ws-dropdown-list">
        {#each activeWorkspaces as workspace (workspace.id)}
          {@const isActive = workspace.id === workspaceStore.activeId}
          <button
            class="ws-item"
            class:ws-item--active={isActive}
            onclick={() => handleSwitch(workspace)}
            role="option"
            aria-selected={isActive}
          >
            <span class="ws-item-icon" aria-hidden="true">
              <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" width="14" height="14">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                  d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z"
                />
              </svg>
            </span>

            <div class="ws-item-info">
              <span class="ws-item-name">{workspace.name}</span>
              <span class="ws-item-meta">
                {workspace.agent_count} agent{workspace.agent_count !== 1 ? 's' : ''}
              </span>
            </div>

            {#if isActive}
              <span class="ws-item-check" aria-hidden="true">
                <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" width="14" height="14">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                </svg>
              </span>
            {:else}
              <span
                class="ws-item-badge"
                aria-label="{workspace.agent_count} agents"
              >
                {workspace.agent_count}
              </span>
            {/if}
          </button>
        {/each}

        {#if activeWorkspaces.length === 0 && !workspaceStore.loading}
          <p class="ws-empty">No workspaces found</p>
        {/if}
      </div>

      <div class="ws-dropdown-footer">
        <button class="ws-create-btn" onclick={handleCreateClick}>
          <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" width="13" height="13" aria-hidden="true">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
          New Workspace
        </button>
      </div>
    </div>
  {/if}
</div>

{#if showCreateModal}
  <CreateWorkspaceModal
    onClose={() => { showCreateModal = false; }}
    onCreated={handleCreated}
  />
{/if}

<style>
  .ws-root {
    position: relative;
    flex-shrink: 0;
    padding: 0 8px;
    margin-bottom: 4px;
  }

  /* Trigger */
  .ws-trigger {
    width: 100%;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 7px 10px;
    border-radius: 6px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    cursor: pointer;
    transition: background 120ms ease, border-color 120ms ease;
    overflow: hidden;
    color: var(--text-secondary, rgba(255, 255, 255, 0.65));
  }

  .ws-trigger:hover {
    background: rgba(255, 255, 255, 0.07);
    border-color: rgba(255, 255, 255, 0.1);
  }

  .ws-trigger--collapsed {
    justify-content: center;
    padding: 7px;
  }

  .ws-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    color: rgba(255, 255, 255, 0.5);
  }

  .ws-name-group {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
    text-align: left;
  }

  .ws-name {
    font-size: 12px;
    font-weight: 500;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text-secondary, rgba(255, 255, 255, 0.65));
  }

  .ws-canopy-label {
    font-size: 9px;
    font-weight: 400;
    letter-spacing: 0.02em;
    color: rgba(255, 255, 255, 0.25);
    white-space: nowrap;
  }

  .ws-chevron {
    display: flex;
    align-items: center;
    flex-shrink: 0;
    color: rgba(255, 255, 255, 0.3);
    transition: transform 200ms ease;
  }

  .ws-chevron--open {
    transform: rotate(180deg);
  }

  /* Collapsed tooltip */
  .ws-tooltip {
    position: fixed;
    left: calc(var(--sidebar-collapsed-width, 48px) + 8px);
    background: #1e1e1e;
    border: 1px solid var(--border-default, rgba(255,255,255,0.1));
    border-radius: 6px;
    padding: 6px 10px;
    font-size: 12px;
    font-weight: 500;
    color: var(--text-primary, #fff);
    pointer-events: none;
    z-index: 200;
    white-space: nowrap;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.5);
    transform: translateY(-50%);
  }

  /* Dropdown panel */
  .ws-dropdown {
    position: absolute;
    top: calc(100% + 4px);
    left: 0;
    right: 0;
    background: rgba(18, 18, 20, 0.92);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 8px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.6), 0 0 0 1px rgba(0,0,0,0.4);
    z-index: 100;
    overflow: hidden;
    min-width: 200px;
  }

  .ws-dropdown--collapsed {
    left: calc(100% + 4px);
    top: 0;
    right: auto;
    width: 220px;
  }

  .ws-dropdown-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 12px 6px;
  }

  .ws-dropdown-title {
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.8px;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.28);
  }

  .ws-loading-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(59, 130, 246, 0.7);
    animation: ws-pulse 1.2s ease-in-out infinite;
  }

  @keyframes ws-pulse {
    0%, 100% { opacity: 0.4; transform: scale(0.85); }
    50% { opacity: 1; transform: scale(1.1); }
  }

  /* Workspace list */
  .ws-dropdown-list {
    display: flex;
    flex-direction: column;
    gap: 1px;
    padding: 2px 6px;
    max-height: 200px;
    overflow-y: auto;
  }

  .ws-item {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 7px 8px;
    border-radius: 6px;
    background: transparent;
    border: none;
    cursor: pointer;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.5));
    transition: background 100ms ease, color 100ms ease;
    text-align: left;
  }

  .ws-item:hover {
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary, rgba(255, 255, 255, 0.65));
  }

  .ws-item--active {
    color: var(--text-primary, rgba(255, 255, 255, 0.9));
    background: rgba(59, 130, 246, 0.08);
  }

  .ws-item-icon {
    display: flex;
    align-items: center;
    flex-shrink: 0;
    color: rgba(255, 255, 255, 0.35);
  }

  .ws-item--active .ws-item-icon {
    color: rgba(59, 130, 246, 0.7);
  }

  .ws-item-info {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .ws-item-name {
    font-size: 12px;
    font-weight: 500;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .ws-item-meta {
    font-size: 10px;
    color: rgba(255, 255, 255, 0.28);
  }

  .ws-item-check {
    display: flex;
    align-items: center;
    color: rgba(59, 130, 246, 0.85);
    flex-shrink: 0;
  }

  .ws-item-badge {
    font-size: 10px;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.25);
    min-width: 16px;
    text-align: right;
    flex-shrink: 0;
  }

  .ws-empty {
    padding: 10px 8px;
    font-size: 12px;
    color: rgba(255, 255, 255, 0.28);
    text-align: center;
  }

  /* Footer */
  .ws-dropdown-footer {
    padding: 6px 6px 8px;
    border-top: 1px solid rgba(255, 255, 255, 0.06);
    margin-top: 2px;
  }

  .ws-create-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    width: 100%;
    padding: 7px 8px;
    border-radius: 6px;
    background: transparent;
    border: none;
    cursor: pointer;
    font-size: 12px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.45);
    transition: background 100ms ease, color 100ms ease;
    text-align: left;
  }

  .ws-create-btn:hover {
    background: rgba(59, 130, 246, 0.08);
    color: rgba(59, 130, 246, 0.85);
  }
</style>
