<script lang="ts">
  import { fly } from 'svelte/transition';
  import { cubicOut } from 'svelte/easing';

  interface Props {
    tool: string;
    description: string;
    paths: string[];
    onAllow: () => void;
    onAllowAlways: () => void;
    onDeny: () => void;
  }

  import ShellPermission from './ShellPermission.svelte';
  import FileEditPermission from './FileEditPermission.svelte';
  import DelegatePermission from './DelegatePermission.svelte';

  let { tool, description, paths, onAllow, onAllowAlways, onDeny }: Props = $props();

  const isShellTool = $derived(tool === 'shell_execute' || tool === 'bash');
  const isFileTool = $derived(tool === 'file_edit' || tool === 'file_write' || tool === 'write_file');
  const isDelegateTool = $derived(tool === 'delegate' || tool === 'spawn_agent');

  // Focus trap refs
  let denyBtn = $state<HTMLButtonElement | null>(null);
  let allowAlwaysBtn = $state<HTMLButtonElement | null>(null);
  let allowOnceBtn = $state<HTMLButtonElement | null>(null);

  // Keyboard shortcut handler
  function handleKeydown(e: KeyboardEvent) {
    switch (e.key) {
      case 'Enter':
        e.preventDefault();
        onAllow();
        break;
      case 'Escape':
      case 'd':
      case 'D':
        e.preventDefault();
        onDeny();
        break;
      case 'a':
      case 'A':
        e.preventDefault();
        onAllowAlways();
        break;
      case 'Tab':
        // Cycle focus through the three buttons only
        e.preventDefault();
        cycleFocus(e.shiftKey);
        break;
    }
  }

  function cycleFocus(reverse: boolean) {
    const buttons = [denyBtn, allowAlwaysBtn, allowOnceBtn].filter(Boolean) as HTMLButtonElement[];
    const active = document.activeElement as HTMLElement;
    const idx = buttons.indexOf(active as HTMLButtonElement);

    if (reverse) {
      const prev = (idx - 1 + buttons.length) % buttons.length;
      buttons[prev]?.focus();
    } else {
      const next = (idx + 1) % buttons.length;
      buttons[next]?.focus();
    }
  }

  // Auto-focus the "Allow once" button on mount (primary action)
  $effect(() => {
    allowOnceBtn?.focus();
  });
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<div
  class="pd-card"
  role="dialog"
  aria-modal="true"
  aria-labelledby="pd-title"
  aria-describedby="pd-description"
  tabindex="-1"
  onkeydown={handleKeydown}
  in:fly={{ y: 20, duration: 220, easing: cubicOut }}
  out:fly={{ y: 12, duration: 160, easing: cubicOut }}
>
  <!-- Header -->
  <div class="pd-header">
    <div class="pd-icon" aria-hidden="true">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        <path
          d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"
          stroke="currentColor"
          stroke-width="1.75"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <line
          x1="12" y1="9" x2="12" y2="13"
          stroke="currentColor"
          stroke-width="1.75"
          stroke-linecap="round"
        />
        <line
          x1="12" y1="17" x2="12.01" y2="17"
          stroke="currentColor"
          stroke-width="2.5"
          stroke-linecap="round"
        />
      </svg>
    </div>
    <div class="pd-title-block">
      <h2 id="pd-title" class="pd-title">Permission required</h2>
      <p id="pd-description" class="pd-subtitle">The agent wants to run a tool</p>
    </div>
  </div>

  <!-- Divider -->
  <div class="pd-divider" aria-hidden="true"></div>

  <!-- Tool info -->
  <div class="pd-body">
    <div class="pd-tool-row">
      <span class="pd-tool-label">Tool</span>
      <code class="pd-tool-name">{tool}</code>
    </div>

    {#if isShellTool}
      <ShellPermission command={description} {paths} />
    {:else if isFileTool}
      <FileEditPermission path={paths[0] || ''} {description} />
    {:else if isDelegateTool}
      <DelegatePermission {description} />
    {:else}
      <p class="pd-description">{description}</p>
    {/if}

    {#if paths.length > 0 && !isShellTool && !isFileTool}
      <div class="pd-paths" aria-label="Affected paths">
        {#each paths as path (path)}
          <div class="pd-path">
            <span class="pd-path-icon" aria-hidden="true">
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                <path
                  d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"
                  stroke="currentColor"
                  stroke-width="1.75"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
                <polyline
                  points="13 2 13 9 20 9"
                  stroke="currentColor"
                  stroke-width="1.75"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
            </span>
            <code class="pd-path-text">{path}</code>
          </div>
        {/each}
      </div>
    {/if}
  </div>

  <!-- Divider -->
  <div class="pd-divider" aria-hidden="true"></div>

  <!-- Actions -->
  <div class="pd-actions">
    <div class="pd-kbd-hint" aria-hidden="true">
      <kbd>D</kbd> deny &nbsp;·&nbsp; <kbd>A</kbd> always &nbsp;·&nbsp; <kbd>↵</kbd> allow
    </div>
    <div class="pd-buttons">
      <button
        bind:this={denyBtn}
        class="pd-btn pd-btn--ghost"
        onclick={onDeny}
        aria-label="Deny (D)"
        type="button"
      >
        Deny
      </button>
      <button
        bind:this={allowAlwaysBtn}
        class="pd-btn pd-btn--ghost"
        onclick={onAllowAlways}
        aria-label="Allow always (A)"
        type="button"
      >
        Allow always
      </button>
      <button
        bind:this={allowOnceBtn}
        class="pd-btn pd-btn--primary"
        onclick={onAllow}
        aria-label="Allow once (Enter)"
        type="button"
      >
        Allow once
      </button>
    </div>
  </div>
</div>

<style>
  .pd-card {
    position: relative;
    width: 420px;
    max-width: calc(100vw - 48px);

    background: rgba(16, 16, 18, 0.92);
    backdrop-filter: blur(40px) saturate(1.6);
    -webkit-backdrop-filter: blur(40px) saturate(1.6);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 16px;
    box-shadow:
      0 0 0 0.5px rgba(255, 255, 255, 0.04) inset,
      0 24px 64px rgba(0, 0, 0, 0.6),
      0 8px 24px rgba(0, 0, 0, 0.4),
      0 2px 8px rgba(0, 0, 0, 0.3);

    overflow: hidden;
    outline: none;
  }

  /* Top accent line — amber */
  .pd-card::before {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 1px;
    background: linear-gradient(
      90deg,
      transparent 0%,
      rgba(245, 158, 11, 0.5) 30%,
      rgba(245, 158, 11, 0.7) 50%,
      rgba(245, 158, 11, 0.5) 70%,
      transparent 100%
    );
  }

  /* ── Header ── */

  .pd-header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 20px 20px 18px;
  }

  .pd-icon {
    width: 36px;
    height: 36px;
    border-radius: 10px;
    background: rgba(245, 158, 11, 0.12);
    border: 1px solid rgba(245, 158, 11, 0.18);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    color: #f59e0b;
  }

  .pd-title-block {
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .pd-title {
    font-size: 14px;
    font-weight: 600;
    color: #ffffff;
    letter-spacing: -0.01em;
    margin: 0;
  }

  .pd-subtitle {
    font-size: 12px;
    color: rgba(255, 255, 255, 0.35);
    margin: 0;
  }

  /* ── Divider ── */

  .pd-divider {
    height: 1px;
    background: linear-gradient(
      90deg,
      transparent 0%,
      rgba(255, 255, 255, 0.06) 20%,
      rgba(255, 255, 255, 0.06) 80%,
      transparent 100%
    );
    margin: 0;
  }

  /* ── Body ── */

  .pd-body {
    padding: 16px 20px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .pd-tool-row {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .pd-tool-label {
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.25);
    flex-shrink: 0;
  }

  .pd-tool-name {
    font-family: var(--font-mono, 'SF Mono', SFMono-Regular, ui-monospace, Menlo, monospace);
    font-size: 12px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.85);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 6px;
    padding: 2px 8px;
    line-height: 1.5;
  }

  .pd-description {
    font-size: 13px;
    line-height: 1.55;
    color: rgba(255, 255, 255, 0.6);
    margin: 0;
  }

  /* ── Path list ── */

  .pd-paths {
    display: flex;
    flex-direction: column;
    gap: 3px;
    border-radius: 8px;
    overflow: hidden;
    background: rgba(255, 255, 255, 0.025);
    border: 1px solid rgba(255, 255, 255, 0.05);
  }

  .pd-path {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 7px 10px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
  }

  .pd-path:last-child {
    border-bottom: none;
  }

  .pd-path-icon {
    color: rgba(255, 255, 255, 0.2);
    flex-shrink: 0;
    display: flex;
    align-items: center;
  }

  .pd-path-text {
    font-family: var(--font-mono, 'SF Mono', SFMono-Regular, ui-monospace, Menlo, monospace);
    font-size: 11.5px;
    color: rgba(255, 255, 255, 0.55);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }

  /* ── Actions ── */

  .pd-actions {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 14px 20px;
  }

  .pd-kbd-hint {
    font-size: 10.5px;
    color: rgba(255, 255, 255, 0.18);
    display: flex;
    align-items: center;
    gap: 2px;
    flex-shrink: 0;
  }

  kbd {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-family: var(--font-mono, 'SF Mono', SFMono-Regular, ui-monospace, Menlo, monospace);
    font-size: 9px;
    font-weight: 600;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 4px;
    padding: 1px 4px;
    line-height: 1.4;
    color: rgba(255, 255, 255, 0.3);
  }

  .pd-buttons {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .pd-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 7px 14px;
    border-radius: 8px;
    font-size: 12.5px;
    font-weight: 500;
    cursor: pointer;
    border: none;
    transition:
      background 0.12s ease,
      color 0.12s ease,
      transform 0.08s ease,
      box-shadow 0.12s ease;
    white-space: nowrap;
    line-height: 1;
  }

  .pd-btn:active {
    transform: scale(0.97);
  }

  .pd-btn:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.35);
    outline-offset: 2px;
  }

  .pd-btn--ghost {
    background: rgba(255, 255, 255, 0.04);
    color: rgba(255, 255, 255, 0.45);
    border: 1px solid rgba(255, 255, 255, 0.07);
  }

  .pd-btn--ghost:hover {
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.75);
    border-color: rgba(255, 255, 255, 0.12);
  }

  .pd-btn--primary {
    background: #ffffff;
    color: #0a0a0a;
    font-weight: 600;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3);
  }

  .pd-btn--primary:hover {
    background: #e8e8e8;
  }

  .pd-btn--primary:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.5);
    outline-offset: 2px;
  }

  @media (prefers-reduced-motion: reduce) {
    .pd-card {
      transition: none;
    }
    .pd-btn {
      transition: none;
    }
  }
</style>
