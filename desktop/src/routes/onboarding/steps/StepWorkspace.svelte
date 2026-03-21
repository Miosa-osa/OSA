<script lang="ts">
  import { untrack } from 'svelte';
  import { open } from '@tauri-apps/plugin-dialog';
  import { homeDir } from '@tauri-apps/api/path';
  import type { WorkspaceConfig } from '$lib/onboarding/types';

  interface Props {
    workspace: WorkspaceConfig;
    onNext: (workspace: WorkspaceConfig) => void;
  }

  let { workspace, onNext }: Props = $props();

  // Use untrack to read the initial prop values without establishing reactive tracking.
  // This component owns these as local state after mount — the prop is only read once.
  let name = $state(untrack(() => workspace.name));
  let description = $state(untrack(() => workspace.description ?? ''));
  let workingDirectory = $state(untrack(() => workspace.workingDirectory));
  let home = $state('');

  $effect(() => {
    homeDir().then((d) => { home = d; });
  });

  let displayPath = $derived(
    home && workingDirectory.startsWith(home)
      ? '~' + workingDirectory.slice(home.length)
      : workingDirectory
  );

  let canContinue = $derived(name.trim().length > 0);

  async function pickDirectory() {
    const selected = await open({
      directory: true,
      defaultPath: workingDirectory || home,
      title: 'Choose workspace directory',
    });
    if (typeof selected === 'string') {
      workingDirectory = selected;
    }
  }

  function handleContinue() {
    if (!canContinue) return;
    onNext({
      name: name.trim(),
      description: description.trim() || undefined,
      workingDirectory,
    });
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' && canContinue && e.target instanceof HTMLInputElement) {
      handleContinue();
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="sw-root">
  <div class="sw-heading">
    <h1 class="sw-title">Set up your workspace</h1>
    <p class="sw-sub">Give your workspace a name and choose where OSA works on your machine.</p>
    <p class="sw-canopy-note">This creates a Canopy workspace — the home for your agents and skills.</p>
  </div>

  <div class="sw-fields">
    <div class="sw-field">
      <label for="sw-name" class="sw-label">Workspace name <span class="sw-required" aria-hidden="true">*</span></label>
      <input
        id="sw-name"
        type="text"
        class="sw-input"
        placeholder="My Project"
        bind:value={name}
        autocomplete="off"
        spellcheck={false}
        aria-required="true"
        aria-describedby="sw-name-hint"
      />
      <p id="sw-name-hint" class="sw-hint">Used to identify this workspace in the app.</p>
    </div>

    <div class="sw-field">
      <label for="sw-desc" class="sw-label">Description <span class="sw-optional">(optional)</span></label>
      <textarea
        id="sw-desc"
        class="sw-textarea"
        placeholder="What is this workspace for?"
        bind:value={description}
        rows="2"
        aria-describedby="sw-desc-hint"
      ></textarea>
      <p id="sw-desc-hint" class="sw-hint">A short mission statement for your agent.</p>
    </div>

    <div class="sw-field">
      <label for="sw-dir" class="sw-label">Working directory</label>
      <div class="sw-dir-row">
        <div
          id="sw-dir"
          class="sw-path-display"
          aria-label="Selected directory: {workingDirectory || 'Home directory'}"
        >
          <span class="sw-path-text">{displayPath || '~/'}</span>
        </div>
        <button
          type="button"
          class="sw-browse-btn"
          aria-label="Choose working directory"
          onclick={pickDirectory}
        >
          <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7a2 2 0 012-2h3.5L10 7h9a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2V7z" />
          </svg>
          Browse
        </button>
      </div>
    </div>
  </div>

  <div class="sw-actions">
    <button
      class="ob-btn ob-btn--primary"
      disabled={!canContinue}
      onclick={handleContinue}
      aria-label="Continue to agent configuration"
    >
      Continue
      <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
      </svg>
    </button>
  </div>
</div>

<style>
  .sw-root {
    display: flex;
    flex-direction: column;
    gap: 20px;
    height: 100%;
  }

  .sw-title {
    font-size: 22px;
    font-weight: 800;
    color: #ffffff;
    letter-spacing: -0.03em;
    margin: 0 0 4px;
  }

  .sw-sub {
    font-size: 13px;
    color: #a0a0a0;
    margin: 0;
    line-height: 1.5;
  }

  .sw-canopy-note {
    font-size: 11px;
    color: #555555;
    margin: 6px 0 0;
    line-height: 1.5;
  }

  .sw-fields {
    display: flex;
    flex-direction: column;
    gap: 14px;
    flex: 1;
  }

  .sw-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .sw-label {
    font-size: 12px;
    font-weight: 500;
    color: #a0a0a0;
    letter-spacing: 0.02em;
  }

  .sw-required {
    color: rgba(239, 68, 68, 0.7);
    margin-left: 2px;
  }

  .sw-optional {
    font-weight: 400;
    color: #555555;
  }

  .sw-input {
    width: 100%;
    padding: 10px 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    color: #ffffff;
    font-size: 13px;
    outline: none;
    transition: border-color 0.15s ease, background 0.15s ease;
    box-sizing: border-box;
  }

  .sw-input::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  .sw-input:focus {
    border-color: rgba(255, 255, 255, 0.25);
    background: rgba(255, 255, 255, 0.06);
  }

  .sw-textarea {
    width: 100%;
    padding: 10px 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    color: #ffffff;
    font-size: 13px;
    outline: none;
    resize: none;
    transition: border-color 0.15s ease, background 0.15s ease;
    box-sizing: border-box;
    font-family: inherit;
    line-height: 1.5;
  }

  .sw-textarea::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  .sw-textarea:focus {
    border-color: rgba(255, 255, 255, 0.25);
    background: rgba(255, 255, 255, 0.06);
  }

  .sw-hint {
    font-size: 11px;
    color: #555555;
    margin: 0;
  }

  .sw-dir-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .sw-path-display {
    flex: 1;
    padding: 10px 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    overflow: hidden;
  }

  .sw-path-text {
    font-size: 13px;
    font-family: 'SF Mono', 'Fira Code', monospace;
    color: #ffffff;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    display: block;
  }

  .sw-browse-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 10px 16px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    color: #a0a0a0;
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    white-space: nowrap;
    transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease;
  }

  .sw-browse-btn:hover {
    background: rgba(255, 255, 255, 0.08);
    border-color: rgba(255, 255, 255, 0.15);
    color: #ffffff;
  }

  .sw-browse-btn:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    outline-offset: 2px;
  }

  .sw-actions {
    margin-top: auto;
    display: flex;
    justify-content: flex-end;
  }
</style>
