<script lang="ts">
  import { fly, fade } from 'svelte/transition';
  import { cubicOut } from 'svelte/easing';

  interface Props {
    onClose: () => void;
  }

  let { onClose }: Props = $props();

  interface ShortcutGroup {
    label: string;
    shortcuts: { keys: string; description: string }[];
  }

  const groups: ShortcutGroup[] = [
    {
      label: 'General',
      shortcuts: [
        { keys: 'Enter', description: 'Send message' },
        { keys: 'Shift+Enter', description: 'New line' },
        { keys: 'Ctrl+C', description: 'Cancel generation' },
        { keys: '/', description: 'Start slash command' },
        { keys: '?', description: 'Toggle this overlay' },
        { keys: 'Ctrl+K', description: 'Clear input' },
      ],
    },
    {
      label: 'Navigation',
      shortcuts: [
        { keys: '⌘1', description: 'Dashboard' },
        { keys: '⌘2', description: 'Chat' },
        { keys: 'Ctrl+N', description: 'New conversation' },
        { keys: 'Ctrl+S', description: 'Toggle sidebar' },
      ],
    },
    {
      label: 'Permissions',
      shortcuts: [
        { keys: 'Enter', description: 'Allow once' },
        { keys: 'A', description: 'Allow always' },
        { keys: 'D / Escape', description: 'Deny' },
        { keys: 'Tab', description: 'Cycle buttons' },
      ],
    },
    {
      label: 'Input',
      shortcuts: [
        { keys: 'Ctrl+J', description: 'Insert newline (CLI)' },
        { keys: '⌘K', description: 'Clear input' },
        { keys: 'Tab', description: 'Autocomplete command' },
      ],
    },
  ];

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape' || e.key === '?') {
      e.preventDefault();
      onClose();
    }
  }

  let dialogEl = $state<HTMLDivElement | null>(null);

  $effect(() => {
    dialogEl?.focus();
  });
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="backdrop"
  onkeydown={handleKeydown}
  onclick={onClose}
  transition:fade={{ duration: 150 }}
>
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <div
    bind:this={dialogEl}
    class="shortcuts-card"
    role="dialog"
    aria-modal="true"
    aria-label="Keyboard shortcuts"
    tabindex="-1"
    onclick={(e) => e.stopPropagation()}
    in:fly={{ y: 20, duration: 220, easing: cubicOut }}
    out:fly={{ y: 12, duration: 160, easing: cubicOut }}
  >
    <div class="header">
      <h2 class="title">Keyboard Shortcuts</h2>
      <button class="close-btn" onclick={onClose} aria-label="Close">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M18 6L6 18M6 6l12 12" />
        </svg>
      </button>
    </div>

    <div class="groups">
      {#each groups as group (group.label)}
        <div class="group">
          <h3 class="group-label">{group.label}</h3>
          {#each group.shortcuts as shortcut (shortcut.keys)}
            <div class="shortcut-row">
              <kbd class="key-badge">{shortcut.keys}</kbd>
              <span class="shortcut-desc">{shortcut.description}</span>
            </div>
          {/each}
        </div>
      {/each}
    </div>

    <div class="footer">
      Press <kbd class="key-badge key-badge--inline">?</kbd> or <kbd class="key-badge key-badge--inline">Esc</kbd> to close
    </div>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: 9999;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.65);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
  }

  .shortcuts-card {
    background: rgba(24, 24, 27, 0.98);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 12px;
    width: 480px;
    max-width: 90vw;
    max-height: 80vh;
    overflow-y: auto;
    box-shadow: 0 24px 48px rgba(0, 0, 0, 0.4);
    outline: none;
  }

  .header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 16px 20px 12px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  }

  .title {
    font-size: 0.9375rem;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.9);
    margin: 0;
  }

  .close-btn {
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.4);
    cursor: pointer;
    padding: 4px;
    border-radius: 4px;
  }

  .close-btn:hover {
    color: rgba(255, 255, 255, 0.7);
    background: rgba(255, 255, 255, 0.06);
  }

  .groups {
    padding: 8px 20px 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .group-label {
    font-size: 0.6875rem;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.35);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    margin: 0 0 8px;
  }

  .shortcut-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 4px 0;
  }

  .key-badge {
    font-family: 'SF Mono', 'Fira Code', 'Cascadia Code', monospace;
    font-size: 0.75rem;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 4px;
    padding: 2px 8px;
    color: rgba(255, 255, 255, 0.7);
    white-space: nowrap;
  }

  .key-badge--inline {
    font-size: 0.6875rem;
    padding: 1px 5px;
  }

  .shortcut-desc {
    font-size: 0.8125rem;
    color: rgba(255, 255, 255, 0.5);
  }

  .footer {
    padding: 12px 20px;
    border-top: 1px solid rgba(255, 255, 255, 0.06);
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.3);
    text-align: center;
  }
</style>
