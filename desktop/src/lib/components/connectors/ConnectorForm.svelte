<script lang="ts">
  import { fade, fly } from 'svelte/transition';
  import type { ConnectorType, ConnectorFormValues } from './types';

  // ── Props ───────────────────────────────────────────────────────────────────

  interface Props {
    onSubmit: (values: ConnectorFormValues) => void;
    onCancel: () => void;
  }

  let { onSubmit, onCancel }: Props = $props();

  // ── Form state ───────────────────────────────────────────────────────────────

  let name        = $state('');
  let type        = $state<ConnectorType>('repo');
  let url         = $state('');
  let description = $state('');

  let isValid = $derived(name.trim().length > 0 && url.trim().length > 0);

  // ── Handlers ─────────────────────────────────────────────────────────────────

  function handleSubmit() {
    if (!isValid) return;
    onSubmit({ name: name.trim(), type, url: url.trim(), description: description.trim() });
    // Reset
    name        = '';
    type        = 'repo';
    url         = '';
    description = '';
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') onCancel();
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
<div class="cf-backdrop" onclick={onCancel} transition:fade={{ duration: 150 }}>
  <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
  <div
    class="cf-card"
    onclick={(e) => e.stopPropagation()}
    onkeydown={handleKeydown}
    transition:fly={{ y: -10, duration: 150 }}
    role="dialog"
    aria-modal="true"
    aria-label="Add connector"
  >
    <h3 class="cf-title">Add Connector</h3>

    <div class="cf-field">
      <label class="cf-label" for="cf-name">Name</label>
      <input
        id="cf-name"
        class="cf-input"
        bind:value={name}
        placeholder="My API Server"
        autocomplete="off"
      />
    </div>

    <div class="cf-field">
      <label class="cf-label" for="cf-type">Type</label>
      <select id="cf-type" class="cf-select" bind:value={type}>
        <option value="repo">Repository</option>
        <option value="server">Server / API</option>
        <option value="app">Application</option>
        <option value="custom">Custom</option>
      </select>
    </div>

    <div class="cf-field">
      <label class="cf-label" for="cf-url">URL / Path</label>
      <input
        id="cf-url"
        class="cf-input"
        bind:value={url}
        placeholder="http://localhost:3000 or /path/to/repo"
        autocomplete="off"
      />
    </div>

    <div class="cf-field">
      <label class="cf-label" for="cf-desc">Description (optional)</label>
      <input
        id="cf-desc"
        class="cf-input"
        bind:value={description}
        placeholder="What this service does"
        autocomplete="off"
      />
    </div>

    <div class="cf-actions">
      <button class="cf-btn cf-btn--ghost" onclick={onCancel}>Cancel</button>
      <button
        class="cf-btn cf-btn--primary"
        onclick={handleSubmit}
        disabled={!isValid}
      >
        Add
      </button>
    </div>
  </div>
</div>

<style>
  .cf-backdrop {
    position: fixed;
    inset: 0;
    z-index: var(--z-modal-backdrop);
    background: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .cf-card {
    z-index: var(--z-modal);
    width: min(440px, calc(100vw - 32px));
    background: rgba(20, 20, 22, 0.95);
    backdrop-filter: blur(40px);
    -webkit-backdrop-filter: blur(40px);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 16px;
    padding: 24px;
    box-shadow: 0 24px 64px rgba(0, 0, 0, 0.6);
  }

  .cf-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 20px;
  }

  .cf-field {
    margin-bottom: 14px;
  }

  .cf-label {
    display: block;
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-secondary);
    margin-bottom: 4px;
  }

  .cf-input {
    width: 100%;
    padding: 8px 12px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border-default);
    border-radius: 8px;
    color: var(--text-primary);
    font-size: 0.875rem;
    outline: none;
    transition: border-color 0.15s;
    box-sizing: border-box;
  }

  .cf-input:focus {
    border-color: var(--border-focus);
  }

  .cf-input::placeholder {
    color: var(--text-muted);
  }

  .cf-select {
    width: 100%;
    padding: 8px 12px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border-default);
    border-radius: 8px;
    color: var(--text-primary);
    font-size: 0.875rem;
    outline: none;
    box-sizing: border-box;
  }

  .cf-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 20px;
  }

  .cf-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    border-radius: 9999px;
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.12s, border-color 0.12s;
  }

  .cf-btn--ghost {
    background: transparent;
    border: 1px solid var(--border-default);
    color: var(--text-secondary);
  }

  .cf-btn--ghost:hover {
    background: rgba(255, 255, 255, 0.05);
    border-color: var(--border-hover);
  }

  .cf-btn--primary {
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.15);
    color: var(--text-primary);
  }

  .cf-btn--primary:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.15);
    border-color: rgba(255, 255, 255, 0.25);
  }

  .cf-btn--primary:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
</style>
