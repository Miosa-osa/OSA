<script lang="ts">
  import { open as openDialog } from '@tauri-apps/plugin-dialog';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import type { Workspace } from '$lib/api/types';

  interface Props {
    onClose: () => void;
    onCreated: (workspace: Workspace) => void;
  }

  let { onClose, onCreated }: Props = $props();

  let name = $state('');
  let description = $state('');
  let directory = $state('');
  let submitting = $state(false);
  let fieldErrors = $state<{ name?: string; directory?: string }>({});

  function validate(): boolean {
    const errs: typeof fieldErrors = {};
    if (!name.trim()) errs.name = 'Name is required';
    if (!directory.trim()) errs.directory = 'Directory is required';
    fieldErrors = errs;
    return Object.keys(errs).length === 0;
  }

  async function pickDirectory() {
    try {
      const selected = await openDialog({ directory: true, multiple: false });
      if (typeof selected === 'string') {
        directory = selected;
        if (fieldErrors.directory) fieldErrors = { ...fieldErrors, directory: undefined };
      }
    } catch {
      // Dialog closed or unavailable in browser dev mode
    }
  }

  async function handleSubmit(e: SubmitEvent) {
    e.preventDefault();
    if (!validate()) return;

    submitting = true;
    workspaceStore.clearError();

    const workspace = await workspaceStore.createWorkspace({
      name: name.trim(),
      description: description.trim() || undefined,
      directory: directory.trim(),
    });

    submitting = false;

    if (workspace) {
      onCreated(workspace);
    }
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (e.key === 'Escape') onClose();
  }

  function handleBackdropClick(e: MouseEvent) {
    if (e.target === e.currentTarget) onClose();
  }
</script>

<svelte:window onkeydown={handleKeyDown} />

<!-- Backdrop -->
<div
  class="cwm-backdrop"
  onclick={handleBackdropClick}
  role="presentation"
  aria-hidden="true"
>
  <!-- Modal panel -->
  <div
    class="cwm-panel"
    role="dialog"
    aria-modal="true"
    aria-labelledby="cwm-title"
    tabindex="-1"
    onclick={(e) => e.stopPropagation()}
    onkeydown={(e) => e.stopPropagation()}
  >
    <header class="cwm-header">
      <h2 class="cwm-title" id="cwm-title">New Workspace</h2>
      <button
        class="cwm-close"
        onclick={onClose}
        aria-label="Close modal"
      >
        <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </header>

    <form class="cwm-form" onsubmit={handleSubmit} novalidate>
      <!-- Name -->
      <div class="cwm-field">
        <label class="cwm-label" for="cwm-name">
          Name <span class="cwm-required" aria-hidden="true">*</span>
        </label>
        <input
          id="cwm-name"
          class="cwm-input"
          class:cwm-input--error={!!fieldErrors.name}
          type="text"
          bind:value={name}
          placeholder="e.g. OSA Main"
          autocomplete="off"
          aria-required="true"
          aria-describedby={fieldErrors.name ? 'cwm-name-err' : undefined}
          oninput={() => { if (fieldErrors.name) fieldErrors = { ...fieldErrors, name: undefined }; }}
        />
        {#if fieldErrors.name}
          <p class="cwm-field-error" id="cwm-name-err" role="alert">{fieldErrors.name}</p>
        {/if}
      </div>

      <!-- Description -->
      <div class="cwm-field">
        <label class="cwm-label" for="cwm-desc">Description</label>
        <input
          id="cwm-desc"
          class="cwm-input"
          type="text"
          bind:value={description}
          placeholder="Describe this Canopy workspace..."
          autocomplete="off"
        />
      </div>

      <!-- Directory -->
      <div class="cwm-field">
        <label class="cwm-label" for="cwm-dir">
          Directory <span class="cwm-required" aria-hidden="true">*</span>
        </label>
        <div class="cwm-dir-row">
          <input
            id="cwm-dir"
            class="cwm-input cwm-dir-input"
            class:cwm-input--error={!!fieldErrors.directory}
            type="text"
            bind:value={directory}
            placeholder="~/projects/my-workspace"
            autocomplete="off"
            aria-required="true"
            aria-describedby={fieldErrors.directory ? 'cwm-dir-err' : undefined}
            oninput={() => { if (fieldErrors.directory) fieldErrors = { ...fieldErrors, directory: undefined }; }}
          />
          <button
            type="button"
            class="cwm-browse-btn"
            onclick={pickDirectory}
            aria-label="Browse for directory"
          >
            <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" width="14" height="14" aria-hidden="true">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                d="M3.75 9.776c.112-.017.227-.026.344-.026h15.812c.117 0 .232.009.344.026m-16.5 0a2.25 2.25 0 00-1.883 2.542l.857 6a2.25 2.25 0 002.227 1.932H19.05a2.25 2.25 0 002.227-1.932l.857-6a2.25 2.25 0 00-1.883-2.542m-16.5 0V6A2.25 2.25 0 016 3.75h3.879a1.5 1.5 0 011.06.44l2.122 2.12a1.5 1.5 0 001.06.44H18A2.25 2.25 0 0120.25 9v.776"
              />
            </svg>
            Browse
          </button>
        </div>
        {#if fieldErrors.directory}
          <p class="cwm-field-error" id="cwm-dir-err" role="alert">{fieldErrors.directory}</p>
        {/if}
      </div>

      <p class="cwm-canopy-hint">
        Creates a Canopy workspace — agents, skills, and knowledge are organized here.
      </p>

      {#if workspaceStore.error}
        <p class="cwm-api-error" role="alert">{workspaceStore.error}</p>
      {/if}

      <footer class="cwm-footer">
        <button type="button" class="cwm-btn cwm-btn--ghost" onclick={onClose}>
          Cancel
        </button>
        <button
          type="submit"
          class="cwm-btn cwm-btn--primary"
          disabled={submitting}
          aria-busy={submitting}
        >
          {#if submitting}
            <span class="cwm-spinner" aria-hidden="true"></span>
            Creating…
          {:else}
            Create Workspace
          {/if}
        </button>
      </footer>
    </form>
  </div>
</div>

<style>
  .cwm-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.55);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    z-index: 500;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px;
  }

  .cwm-panel {
    width: 100%;
    max-width: 440px;
    background: rgba(18, 18, 20, 0.95);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 12px;
    box-shadow: 0 24px 64px rgba(0, 0, 0, 0.7), 0 0 0 1px rgba(0,0,0,0.4);
    overflow: hidden;
  }

  .cwm-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 18px 20px 0;
  }

  .cwm-title {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-primary, rgba(255, 255, 255, 0.9));
    margin: 0;
  }

  .cwm-close {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border-radius: 6px;
    background: transparent;
    border: none;
    cursor: pointer;
    color: rgba(255, 255, 255, 0.35);
    transition: background 100ms ease, color 100ms ease;
  }

  .cwm-close:hover {
    background: rgba(255, 255, 255, 0.07);
    color: rgba(255, 255, 255, 0.7);
  }

  .cwm-form {
    display: flex;
    flex-direction: column;
    gap: 14px;
    padding: 18px 20px 20px;
  }

  .cwm-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .cwm-label {
    font-size: 12px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.5);
    user-select: none;
  }

  .cwm-required {
    color: rgba(239, 68, 68, 0.7);
    margin-left: 2px;
  }

  .cwm-input {
    width: 100%;
    padding: 8px 10px;
    font-size: 13px;
    color: var(--text-primary, rgba(255, 255, 255, 0.9));
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 7px;
    outline: none;
    transition: border-color 120ms ease, background 120ms ease;
    box-sizing: border-box;
  }

  .cwm-input::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  .cwm-input:focus {
    border-color: rgba(59, 130, 246, 0.45);
    background: rgba(255, 255, 255, 0.06);
  }

  .cwm-input--error {
    border-color: rgba(239, 68, 68, 0.5);
  }

  .cwm-dir-row {
    display: flex;
    gap: 6px;
  }

  .cwm-dir-input {
    flex: 1;
  }

  .cwm-browse-btn {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 8px 12px;
    font-size: 12px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.5);
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 7px;
    cursor: pointer;
    white-space: nowrap;
    flex-shrink: 0;
    transition: background 100ms ease, color 100ms ease, border-color 100ms ease;
  }

  .cwm-browse-btn:hover {
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.75);
    border-color: rgba(255, 255, 255, 0.14);
  }

  .cwm-field-error {
    font-size: 11px;
    color: rgba(239, 68, 68, 0.85);
    margin: 0;
  }

  .cwm-api-error {
    font-size: 12px;
    color: rgba(239, 68, 68, 0.85);
    background: rgba(239, 68, 68, 0.08);
    border: 1px solid rgba(239, 68, 68, 0.2);
    border-radius: 6px;
    padding: 8px 10px;
    margin: 0;
  }

  .cwm-footer {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    padding-top: 4px;
  }

  .cwm-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 8px 16px;
    font-size: 13px;
    font-weight: 500;
    border-radius: 7px;
    cursor: pointer;
    border: none;
    transition: background 120ms ease, color 120ms ease, opacity 120ms ease;
  }

  .cwm-btn:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }

  .cwm-btn--ghost {
    background: rgba(255, 255, 255, 0.05);
    color: rgba(255, 255, 255, 0.5);
  }

  .cwm-btn--ghost:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.75);
  }

  .cwm-btn--primary {
    background: rgba(59, 130, 246, 0.85);
    color: #fff;
  }

  .cwm-btn--primary:hover:not(:disabled) {
    background: rgba(59, 130, 246, 1);
  }

  .cwm-canopy-hint {
    font-size: 11px;
    color: rgba(255, 255, 255, 0.25);
    margin: 0;
    line-height: 1.5;
  }

  .cwm-spinner {
    width: 12px;
    height: 12px;
    border: 2px solid rgba(255, 255, 255, 0.25);
    border-top-color: #fff;
    border-radius: 50%;
    animation: cwm-spin 0.7s linear infinite;
  }

  @keyframes cwm-spin {
    to { transform: rotate(360deg); }
  }
</style>
