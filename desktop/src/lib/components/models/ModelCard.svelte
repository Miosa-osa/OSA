<script lang="ts">
  import type { Model } from '$lib/api/types';

  // ── Props ────────────────────────────────────────────────────────────────────

  interface Props {
    model: Model;
    switching: string | null;
    onActivate: (model: Model) => void;
  }

  let { model, switching, onActivate }: Props = $props();

  // ── Derived ──────────────────────────────────────────────────────────────────

  let isActive = $derived(model.active);
  let isSwitching = $derived(switching === model.name);
  let isDisabled = $derived(isSwitching || switching !== null);

  let caps = $derived(modelCapabilities(model));
  let status = $derived(modelStatus(model));

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function formatContext(ctx: number): string {
    if (ctx >= 1_000_000) return `${(ctx / 1_000_000).toFixed(0)}M ctx`;
    if (ctx >= 1_000) return `${Math.round(ctx / 1_000)}K ctx`;
    return `${ctx} ctx`;
  }

  function modelCapabilities(m: Model): string[] {
    const caps: string[] = [];
    const name = m.name.toLowerCase();
    const desc = (m.description ?? '').toLowerCase();

    if (name.includes('vision') || desc.includes('vision') || desc.includes('image') || desc.includes('multimodal')) {
      caps.push('vision');
    }
    if (
      name.includes('reason') || desc.includes('reason') ||
      name.includes('thinking') || desc.includes('thinking') ||
      name.includes('r1') || name.includes('o1') || name.includes('o3') || name.includes('o4') ||
      name.includes('qwq')
    ) {
      caps.push('reasoning');
    }
    if (name.includes('code') || desc.includes('code') || desc.includes('coding')) {
      caps.push('code');
    }
    if (
      desc.includes('tool use') || desc.includes('tool_use') ||
      name.includes('claude') || name.includes('gpt-4') ||
      name.includes('llama-3.3') || name.includes('llama-4')
    ) {
      caps.push('tool use');
    }
    if (m.context_window >= 100_000) {
      caps.push('long ctx');
    }
    if (m.is_local) {
      caps.push('local');
    }
    if (m.requires_api_key && !m.is_local) {
      caps.push('cloud');
    }
    return caps;
  }

  function modelStatus(m: Model): 'active' | 'available' | 'unreachable' {
    if (m.active) return 'active';
    return 'available';
  }
</script>

<li
  class="mc-row"
  class:mc-row--active={isActive}
  aria-label="{model.name}{isActive ? ' (active)' : ''}"
>
  <!-- Left: name + badges -->
  <div class="mc-info">
    <div class="mc-name-row">
      <span class="mc-name">{model.name}</span>
      {#if model.size}
        <span class="mc-size">{model.size}</span>
      {/if}
    </div>
    {#if model.description}
      <span class="mc-desc">{model.description}</span>
    {/if}

    <div class="mc-badges" aria-label="Model details">
      <span class="mc-badge mc-badge--ctx" aria-label="Context window: {model.context_window}">
        {formatContext(model.context_window)}
      </span>

      {#each caps as cap}
        <span class="mc-badge mc-badge--cap">{cap}</span>
      {/each}

      {#if status === 'active'}
        <span class="mc-badge mc-badge--active" aria-label="Currently active">
          <span class="mc-status-dot mc-status-dot--active" aria-hidden="true"></span>
          active
        </span>
      {:else if status === 'unreachable'}
        <span class="mc-badge mc-badge--unreachable" aria-label="Model unreachable">
          <span class="mc-status-dot mc-status-dot--unreachable" aria-hidden="true"></span>
          unreachable
        </span>
      {/if}
    </div>
  </div>

  <!-- Right: action -->
  <div class="mc-actions">
    {#if isActive}
      <span class="mc-in-use" aria-label="This model is in use">In use</span>
    {:else}
      <button
        class="mc-use-btn"
        aria-label="Use {model.name}"
        disabled={isDisabled}
        onclick={() => onActivate(model)}
      >
        {#if isSwitching}
          <span class="mc-spinner" aria-hidden="true"></span>
          Switching…
        {:else}
          Use
        {/if}
      </button>
    {/if}
  </div>
</li>

<style>
  .mc-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 11px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    transition: background 0.15s ease, border-left-color 0.15s ease;
    border-left: 2px solid transparent;
    list-style: none;
  }

  .mc-row:last-child {
    border-bottom: none;
  }

  .mc-row:hover {
    background: rgba(255, 255, 255, 0.025);
  }

  .mc-row--active {
    border-left-color: var(--accent-primary);
    background: rgba(59, 130, 246, 0.04);
  }

  .mc-row--active:hover {
    background: rgba(59, 130, 246, 0.07);
  }

  /* ── Info ── */

  .mc-info {
    display: flex;
    flex-direction: column;
    gap: 5px;
    min-width: 0;
    flex: 1;
  }

  .mc-name-row {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }

  .mc-name {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
    font-family: var(--font-mono);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .mc-size {
    font-size: 11px;
    font-weight: 500;
    color: var(--text-tertiary);
    white-space: nowrap;
    flex-shrink: 0;
  }

  .mc-desc {
    font-size: 11px;
    line-height: 1.4;
    color: var(--text-muted, rgba(255, 255, 255, 0.35));
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 500px;
  }

  .mc-badges {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    align-items: center;
  }

  /* ── Badges ── */

  .mc-badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 7px;
    border-radius: var(--radius-full);
    font-size: 10px;
    font-weight: 500;
    border: 1px solid transparent;
  }

  .mc-badge--ctx {
    background: rgba(255, 255, 255, 0.06);
    border-color: rgba(255, 255, 255, 0.08);
    color: var(--text-secondary);
    font-family: var(--font-mono);
  }

  .mc-badge--cap {
    background: rgba(255, 255, 255, 0.04);
    border-color: rgba(255, 255, 255, 0.06);
    color: var(--text-tertiary);
  }

  .mc-badge--active {
    background: rgba(34, 197, 94, 0.1);
    border-color: rgba(34, 197, 94, 0.2);
    color: #86efac;
  }

  .mc-badge--unreachable {
    background: rgba(239, 68, 68, 0.08);
    border-color: rgba(239, 68, 68, 0.18);
    color: #fca5a5;
  }

  .mc-status-dot {
    width: 5px;
    height: 5px;
    border-radius: 9999px;
  }

  .mc-status-dot--active {
    background: var(--accent-success);
    animation: mc-pulse 2s ease-in-out infinite;
  }

  .mc-status-dot--unreachable {
    background: var(--accent-error);
  }

  /* ── Actions ── */

  .mc-actions {
    flex-shrink: 0;
  }

  .mc-in-use {
    font-size: 11px;
    font-weight: 500;
    color: var(--text-tertiary);
    padding: 0 4px;
  }

  .mc-use-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 14px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: var(--radius-full);
    font-size: 12px;
    font-weight: 600;
    color: var(--text-primary);
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, opacity 0.15s ease;
    white-space: nowrap;
  }

  .mc-use-btn:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.18);
  }

  .mc-use-btn:active:not(:disabled) {
    transform: scale(0.97);
  }

  .mc-use-btn:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }

  .mc-use-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* ── Spinner ── */

  .mc-spinner {
    width: 10px;
    height: 10px;
    border-radius: 9999px;
    border: 2px solid rgba(255, 255, 255, 0.15);
    border-top-color: rgba(255, 255, 255, 0.7);
    animation: mc-spin 0.7s linear infinite;
  }

  /* ── Keyframes ── */

  @keyframes mc-pulse {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0.4; }
  }

  @keyframes mc-spin {
    to { transform: rotate(360deg); }
  }

  @media (prefers-reduced-motion: reduce) {
    .mc-status-dot--active { animation: none; }
    .mc-spinner { animation: none; border-top-color: rgba(255, 255, 255, 0.5); }
  }
</style>
