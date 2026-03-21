<script lang="ts">
  import { open as openDialog } from '@tauri-apps/plugin-dialog';
  import { themeStore } from '$lib/stores/theme.svelte';
  import type { ThemeMode } from '$lib/stores/theme.svelte';

  interface Props {
    agentName: string;
    workingDir: string;
    saving: boolean;
    saveSuccess: boolean;
    onAgentNameChange: (v: string) => void;
    onWorkingDirChange: (v: string) => void;
    onSave: () => void;
  }

  let {
    agentName,
    workingDir,
    saving,
    saveSuccess,
    onAgentNameChange,
    onWorkingDirChange,
    onSave,
  }: Props = $props();

  async function pickWorkingDir() {
    try {
      const selected = await openDialog({ directory: true, multiple: false });
      if (typeof selected === 'string') onWorkingDirChange(selected);
    } catch {
      // dialog unavailable outside Tauri
    }
  }
</script>

<section class="sg-section">
  <h2 class="sg-section-title">General</h2>
  <p class="sg-section-desc">Workspace and display preferences.</p>

  <div class="sg-settings-group">
    <!-- Agent name -->
    <div class="sg-settings-item">
      <div class="sg-item-meta">
        <span class="sg-item-label">Agent name</span>
        <span class="sg-item-hint">Name shown in chat and logs.</span>
      </div>
      <input
        type="text"
        class="sg-field-input"
        value={agentName}
        oninput={(e) => onAgentNameChange((e.target as HTMLInputElement).value)}
        placeholder="OSA Agent"
        aria-label="Agent name"
        maxlength="64"
      />
    </div>

    <div class="sg-item-divider"></div>

    <!-- Working directory -->
    <div class="sg-settings-item">
      <div class="sg-item-meta">
        <span class="sg-item-label">Working directory</span>
        <span class="sg-item-hint">Default root for file operations.</span>
      </div>
      <div class="sg-dir-row">
        <input
          type="text"
          class="sg-field-input sg-dir-input"
          value={workingDir}
          oninput={(e) => onWorkingDirChange((e.target as HTMLInputElement).value)}
          placeholder="/Users/you/projects"
          aria-label="Working directory path"
          spellcheck={false}
        />
        <button
          type="button"
          class="sg-btn-ghost sg-btn-sm"
          onclick={pickWorkingDir}
          aria-label="Browse for working directory"
        >
          <svg width="13" height="13" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7a2 2 0 012-2h3.586a1 1 0 01.707.293L10.707 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V7z"/></svg>
          Browse
        </button>
      </div>
    </div>

    <div class="sg-item-divider"></div>

    <!-- Theme -->
    <div class="sg-settings-item">
      <div class="sg-item-meta">
        <span class="sg-item-label">Theme</span>
        <span class="sg-item-hint">Follows system setting when set to System.</span>
      </div>
      <select
        class="sg-field-select"
        value={themeStore.mode}
        onchange={(e) => themeStore.setMode((e.target as HTMLSelectElement).value as ThemeMode)}
        aria-label="Theme"
      >
        <option value="system">System</option>
        <option value="dark">Dark</option>
        <option value="light">Light</option>
      </select>
    </div>
  </div>

  <div class="sg-save-row">
    <button
      type="button"
      class="sg-btn-primary"
      onclick={onSave}
      disabled={saving}
    >
      {#if saving}
        <span class="sg-spinner" aria-hidden="true"></span>
        Saving…
      {:else if saveSuccess}
        <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M5 13l4 4L19 7"/></svg>
        Saved
      {:else}
        Save changes
      {/if}
    </button>
  </div>
</section>

<style>
  .sg-section { max-width: 560px; }
  .sg-section-title { font-size: 18px; font-weight: 700; color: var(--text-primary); letter-spacing: -0.02em; margin: 0 0 4px; }
  .sg-section-desc { font-size: 13px; color: var(--text-tertiary); margin: 0 0 24px; }

  .sg-settings-group { background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.07); border-radius: 12px; overflow: hidden; }
  .sg-settings-item { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 13px 16px; min-height: 52px; }
  .sg-item-divider { height: 1px; background: rgba(255,255,255,0.06); }
  .sg-item-meta { display: flex; flex-direction: column; gap: 2px; flex-shrink: 0; }
  .sg-item-label { font-size: 14px; color: rgba(255,255,255,0.88); font-weight: 450; white-space: nowrap; }
  .sg-item-hint { font-size: 11.5px; color: var(--text-tertiary); }

  .sg-field-input {
    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.09); border-radius: 8px;
    padding: 7px 12px; color: rgba(255,255,255,0.9); font-size: 13px; outline: none;
    transition: border-color 0.15s ease, background 0.15s ease; width: 220px; min-width: 0;
  }
  .sg-field-input::placeholder { color: rgba(255,255,255,0.2); }
  .sg-field-input:focus { border-color: rgba(255,255,255,0.22); background: rgba(255,255,255,0.07); }

  .sg-field-select {
    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.09); border-radius: 8px;
    padding: 7px 28px 7px 12px; color: rgba(255,255,255,0.9); font-size: 13px; outline: none; cursor: pointer;
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 24 24' fill='none' stroke='%23666' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M6 9l6 6 6-6'/%3E%3C/svg%3E");
    background-repeat: no-repeat; background-position: right 10px center; transition: border-color 0.15s ease;
  }
  .sg-field-select:focus { border-color: rgba(255,255,255,0.22); }
  .sg-dir-row { display: flex; align-items: center; gap: 8px; }
  .sg-dir-input { width: 180px; }

  .sg-btn-primary {
    display: inline-flex; align-items: center; gap: 6px; padding: 8px 18px;
    background: rgba(255,255,255,0.1); border: 1px solid rgba(255,255,255,0.14); border-radius: 9999px;
    color: rgba(255,255,255,0.9); font-size: 13px; font-weight: 500; cursor: pointer;
    backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
    transition: background 0.15s ease, border-color 0.15s ease, box-shadow 0.15s ease;
  }
  .sg-btn-primary:hover:not(:disabled) { background: rgba(255,255,255,0.16); border-color: rgba(255,255,255,0.22); box-shadow: inset 0 0 0 1px rgba(255,255,255,0.08); }
  .sg-btn-primary:disabled { opacity: 0.5; cursor: not-allowed; }
  .sg-btn-primary:focus-visible { outline: 2px solid rgba(255,255,255,0.3); outline-offset: 2px; }

  .sg-btn-ghost {
    display: inline-flex; align-items: center; gap: 6px; padding: 7px 14px;
    background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 9999px;
    color: rgba(255,255,255,0.6); font-size: 13px; font-weight: 450; cursor: pointer;
    transition: background 0.13s ease, color 0.13s ease, border-color 0.13s ease;
  }
  .sg-btn-ghost:hover:not(:disabled) { background: rgba(255,255,255,0.07); color: rgba(255,255,255,0.85); border-color: rgba(255,255,255,0.13); }
  .sg-btn-sm { padding: 6px 10px; font-size: 12px; }
  .sg-save-row { margin-top: 20px; display: flex; align-items: center; gap: 12px; }

  .sg-spinner { display: inline-block; width: 13px; height: 13px; border: 2px solid rgba(255,255,255,0.2); border-top-color: rgba(255,255,255,0.8); border-radius: 9999px; animation: sg-spin 0.6s linear infinite; flex-shrink: 0; }
  @keyframes sg-spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) { .sg-spinner { animation: none; opacity: 0.5; } }
</style>
