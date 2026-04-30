<script lang="ts">
  import { open } from '@tauri-apps/plugin-dialog';
  import { homeDir } from '@tauri-apps/api/path';

  interface Props {
    workingDirectory: string;
    onNext: () => void;
    onBack: () => void;
  }

  let { workingDirectory = $bindable(), onNext, onBack }: Props = $props();

  let home = $state('');

  $effect(() => {
    homeDir().then((d) => { home = d; });
  });

  // Display path: replace home prefix with ~
  let displayPath = $derived(
    home && workingDirectory.startsWith(home)
      ? '~' + workingDirectory.slice(home.length)
      : workingDirectory
  );

  async function pickDirectory() {
    const selected = await open({
      directory: true,
      defaultPath: workingDirectory,
      title: 'Choose working directory',
    });
    if (typeof selected === 'string') {
      workingDirectory = selected;
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter') onNext();
    if (e.key === 'Escape') onBack();
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="sd-root">
  <div class="sd-heading">
    <h1 class="sd-title">Where should OSA work?</h1>
    <p class="sd-sub">OSA reads and writes files here by default. You can change this any time in Settings.</p>
  </div>

  <div class="sd-picker">
    <label for="sd-path" class="sd-label">Working Directory</label>
    <div class="sd-row">
      <div class="sd-path-display" id="sd-path" aria-label="Selected directory: {workingDirectory}">
        <span class="sd-path-text">{displayPath || '~/'}</span>
      </div>
      <button
        type="button"
        class="sd-browse-btn"
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

  <div class="sd-actions">
    <button class="ob-btn ob-btn--ghost" onclick={onBack}>
      Back
    </button>
    <div class="sd-actions-right">
      <button class="ob-btn ob-btn--ghost" onclick={onNext}>
        Skip
      </button>
      <button class="ob-btn ob-btn--primary" onclick={onNext}>
        Start with OSA
        <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
        </svg>
      </button>
    </div>
  </div>
</div>

<style>
  .sd-root {
    display: flex;
    flex-direction: column;
    gap: 24px;
    height: 100%;
  }

  .sd-title {
    font-size: 22px;
    font-weight: 800;
    color: #ffffff;
    letter-spacing: -0.03em;
    margin: 0 0 4px;
  }

  .sd-sub {
    font-size: 13px;
    color: #a0a0a0;
    margin: 0;
    line-height: 1.5;
  }

  .sd-picker {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .sd-label {
    font-size: 12px;
    font-weight: 500;
    color: #a0a0a0;
    letter-spacing: 0.02em;
  }

  .sd-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .sd-path-display {
    flex: 1;
    padding: 11px 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    overflow: hidden;
  }

  .sd-path-text {
    font-size: 13px;
    font-family: 'SF Mono', 'Fira Code', monospace;
    color: #ffffff;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    display: block;
  }

  .sd-browse-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 11px 16px;
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

  .sd-browse-btn:hover {
    background: rgba(255, 255, 255, 0.08);
    border-color: rgba(255, 255, 255, 0.15);
    color: #ffffff;
  }

  .sd-browse-btn:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    outline-offset: 2px;
  }

  .sd-actions {
    margin-top: auto;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .sd-actions-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }
</style>
