<script lang="ts">
  import { fly } from 'svelte/transition';
  import type { Toast } from '$lib/stores/toasts.svelte';
  import { toastStore } from '$lib/stores/toasts.svelte';

  interface Props {
    toast: Toast;
  }

  let { toast }: Props = $props();

  const COLORS: Record<Toast['type'], { bg: string; border: string; icon: string; glow: string }> =
    {
      info: {
        bg: 'rgba(59, 130, 246, 0.08)',
        border: 'rgba(59, 130, 246, 0.25)',
        icon: 'rgba(59, 130, 246, 0.9)',
        glow: 'rgba(59, 130, 246, 0.15)',
      },
      success: {
        bg: 'rgba(34, 197, 94, 0.08)',
        border: 'rgba(34, 197, 94, 0.25)',
        icon: 'rgba(34, 197, 94, 0.9)',
        glow: 'rgba(34, 197, 94, 0.15)',
      },
      warning: {
        bg: 'rgba(251, 191, 36, 0.08)',
        border: 'rgba(251, 191, 36, 0.25)',
        icon: 'rgba(251, 191, 36, 0.9)',
        glow: 'rgba(251, 191, 36, 0.15)',
      },
      error: {
        bg: 'rgba(239, 68, 68, 0.08)',
        border: 'rgba(239, 68, 68, 0.25)',
        icon: 'rgba(239, 68, 68, 0.9)',
        glow: 'rgba(239, 68, 68, 0.15)',
      },
    };

  // SVG icon paths keyed by type
  const ICONS: Record<Toast['type'], string> = {
    info: 'M11.25 11.25l.041-.02a.75.75 0 011.063.852l-.708 2.836a.75.75 0 001.063.853l.041-.021M21 12a9 9 0 11-18 0 9 9 0 0118 0zm-9-3.75h.008v.008H12V8.25z',
    success:
      'M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z',
    warning:
      'M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z',
    error:
      'M9.75 9.75l4.5 4.5m0-4.5l-4.5 4.5M21 12a9 9 0 11-18 0 9 9 0 0118 0z',
  };

  const c = $derived(COLORS[toast.type]);
</script>

<div
  class="tn-toast"
  style:background={c.bg}
  style:border-color={c.border}
  style:box-shadow="0 4px 24px {c.glow}, 0 1px 4px rgba(0,0,0,0.4)"
  in:fly={{ x: 64, duration: 220, opacity: 0 }}
  out:fly={{ x: 64, duration: 180, opacity: 0 }}
  role="alert"
  aria-live="polite"
>
  <!-- Type icon -->
  <svg
    class="tn-icon"
    style:color={c.icon}
    fill="none"
    stroke="currentColor"
    viewBox="0 0 24 24"
    aria-hidden="true"
    width="18"
    height="18"
  >
    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d={ICONS[toast.type]} />
  </svg>

  <!-- Text content -->
  <div class="tn-body">
    <p class="tn-title">{toast.title}</p>
    {#if toast.message}
      <p class="tn-message">{toast.message}</p>
    {/if}
  </div>

  <!-- Dismiss button -->
  <button
    class="tn-close"
    onclick={() => toastStore.dismiss(toast.id)}
    aria-label="Dismiss notification"
  >
    <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true" width="14" height="14">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
    </svg>
  </button>
</div>

<style>
  .tn-toast {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 11px 12px;
    border-radius: 10px;
    border: 1px solid transparent;
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    width: 320px;
    max-width: calc(100vw - 32px);
    pointer-events: auto;
  }

  .tn-icon {
    flex-shrink: 0;
    margin-top: 1px;
  }

  .tn-body {
    flex: 1;
    min-width: 0;
  }

  .tn-title {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary, rgba(255, 255, 255, 0.92));
    line-height: 1.3;
  }

  .tn-message {
    margin-top: 2px;
    font-size: 12px;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.5));
    line-height: 1.4;
  }

  .tn-close {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 5px;
    border: none;
    background: transparent;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    cursor: pointer;
    transition: background 120ms, color 120ms;
    margin-top: -1px;
  }

  .tn-close:hover {
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-secondary, rgba(255, 255, 255, 0.7));
  }
</style>
