<script lang="ts">
  import type { Model } from '$lib/api/types';

  // ── Props ────────────────────────────────────────────────────────────────────

  interface Props {
    current: Model | null;
    currentLabel: string;
    switching: string | null;
    switchError: string | null;
  }

  let { current, currentLabel, switching, switchError }: Props = $props();

  let isSwitching = $derived(switching !== null);
</script>

<div class="ms-root">
  {#if isSwitching}
    <div class="ms-badge ms-badge--switching" aria-label="Switching model: {switching}">
      <span class="ms-spinner" aria-hidden="true"></span>
      <span class="ms-label">Switching to {switching}…</span>
    </div>
  {:else if current}
    <div class="ms-badge" aria-label="Active model: {currentLabel}">
      <span class="ms-dot" aria-hidden="true"></span>
      <span class="ms-label">{currentLabel}</span>
    </div>
  {/if}

  {#if switchError}
    <div class="ms-error" role="alert" aria-live="polite">
      <span class="ms-error-dot" aria-hidden="true"></span>
      <span class="ms-error-text">{switchError}</span>
    </div>
  {/if}
</div>

<style>
  .ms-root {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }

  .ms-badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 10px;
    background: rgba(59, 130, 246, 0.1);
    border: 1px solid rgba(59, 130, 246, 0.25);
    border-radius: var(--radius-full);
    font-size: 11px;
    font-weight: 500;
    color: #93bbfd;
    font-family: var(--font-mono);
    max-width: 280px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .ms-badge--switching {
    background: rgba(251, 191, 36, 0.08);
    border-color: rgba(251, 191, 36, 0.2);
    color: rgba(251, 191, 36, 0.85);
  }

  .ms-dot {
    width: 6px;
    height: 6px;
    border-radius: 9999px;
    background: var(--accent-success);
    flex-shrink: 0;
    animation: ms-pulse 2s ease-in-out infinite;
  }

  .ms-label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* ── Switch spinner ── */

  .ms-spinner {
    width: 10px;
    height: 10px;
    border-radius: 9999px;
    border: 2px solid rgba(251, 191, 36, 0.2);
    border-top-color: rgba(251, 191, 36, 0.8);
    animation: ms-spin 0.7s linear infinite;
    flex-shrink: 0;
  }

  /* ── Error ── */

  .ms-error {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 3px 10px;
    background: rgba(239, 68, 68, 0.08);
    border: 1px solid rgba(239, 68, 68, 0.2);
    border-radius: var(--radius-full);
    font-size: 11px;
    color: #fca5a5;
    max-width: 320px;
    overflow: hidden;
  }

  .ms-error-dot {
    width: 6px;
    height: 6px;
    border-radius: 9999px;
    background: rgba(239, 68, 68, 0.8);
    flex-shrink: 0;
  }

  .ms-error-text {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* ── Keyframes ── */

  @keyframes ms-pulse {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0.4; }
  }

  @keyframes ms-spin {
    to { transform: rotate(360deg); }
  }

  @media (prefers-reduced-motion: reduce) {
    .ms-dot { animation: none; }
    .ms-spinner { animation: none; border-top-color: rgba(251, 191, 36, 0.6); }
  }
</style>
