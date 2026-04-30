<script lang="ts">
  import type { Provider, DetectionResult } from '$lib/onboarding/types';
  import { PROVIDERS } from '$lib/onboarding/types';

  interface Props {
    provider: Provider | null;
    detectedProviders: DetectionResult;
    detecting: boolean;
    onSelect: (p: Provider) => void;
    onNext: () => void;
  }

  let { provider, detectedProviders, detecting, onSelect, onNext }: Props = $props();

  let canContinue = $derived(provider !== null);

  function isDetected(id: Provider): boolean {
    return (id === 'ollama' && detectedProviders.ollama) ||
           (id === 'lmstudio' && detectedProviders.lmstudio);
  }

  function handleRadioKeydown(e: KeyboardEvent) {
    const ids = PROVIDERS.map((p) => p.id);
    const idx = ids.indexOf(provider ?? ids[0]);

    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
      e.preventDefault();
      onSelect(ids[(idx + 1) % ids.length]);
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
      e.preventDefault();
      onSelect(ids[(idx - 1 + ids.length) % ids.length]);
    } else if (e.key === 'Enter' && canContinue) {
      onNext();
    }
  }
</script>

<div class="sp-root">
  <div class="sp-heading">
    <h1 class="sp-title">Welcome to OSA</h1>
    <p class="sp-sub">Choose how you want to run your AI.</p>
  </div>

  <div
    class="sp-grid"
    role="radiogroup"
    aria-label="AI provider"
    tabindex="0"
    onkeydown={handleRadioKeydown}
  >
    {#each PROVIDERS as meta}
      {@const detected = isDetected(meta.id)}
      {@const selected = provider === meta.id}
      <button
        class="sp-card"
        class:sp-card--selected={selected}
        class:sp-card--detected={detected}
        role="radio"
        aria-checked={selected}
        aria-describedby="sp-desc-{meta.id}"
        onclick={() => onSelect(meta.id)}
        ondblclick={onNext}
      >
        <!-- Radio indicator -->
        <div class="sp-radio" class:sp-radio--on={selected} aria-hidden="true">
          {#if selected}
            <div class="sp-radio-inner"></div>
          {/if}
        </div>

        <div class="sp-card-body">
          <span class="sp-card-name">{meta.name}</span>
          <span class="sp-card-tagline" id="sp-desc-{meta.id}">{meta.tagline}</span>

          {#if detecting && (meta.id === 'ollama' || meta.id === 'lmstudio')}
            <span class="sp-badge sp-badge--detecting" aria-label="Detecting...">
              <span class="sp-badge-dot sp-badge-dot--shimmer"></span>
              Detecting
            </span>
          {:else if detected}
            <span class="sp-badge sp-badge--detected">
              <span class="sp-badge-dot"></span>
              Detected
            </span>
          {/if}
        </div>
      </button>
    {/each}
  </div>

  <div class="sp-actions">
    <button
      class="ob-btn ob-btn--primary"
      disabled={!canContinue}
      onclick={onNext}
    >
      Continue
      <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
      </svg>
    </button>
  </div>
</div>

<style>
  .sp-root {
    display: flex;
    flex-direction: column;
    gap: 24px;
    height: 100%;
  }

  .sp-title {
    font-size: 22px;
    font-weight: 800;
    color: #ffffff;
    letter-spacing: -0.03em;
    margin: 0 0 4px;
  }

  .sp-sub {
    font-size: 13px;
    color: #a0a0a0;
    margin: 0;
  }

  .sp-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
    flex: 1;
    align-content: start;
  }

  .sp-card {
    position: relative;
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 14px 14px;
    border-radius: 12px;
    text-align: left;
    cursor: pointer;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.07);
    transition: border-color 0.15s ease, background 0.15s ease, box-shadow 0.15s ease;
    color: inherit;
  }

  .sp-card:hover {
    background: rgba(255, 255, 255, 0.04);
    border-color: rgba(255, 255, 255, 0.12);
  }

  .sp-card:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    outline-offset: 2px;
  }

  .sp-card--selected {
    background: rgba(255, 255, 255, 0.05);
    border-color: rgba(255, 255, 255, 0.22);
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08);
  }

  .sp-radio {
    width: 16px;
    height: 16px;
    border-radius: 9999px;
    border: 2px solid rgba(255, 255, 255, 0.2);
    flex-shrink: 0;
    margin-top: 1px;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: border-color 0.15s ease;
  }

  .sp-radio--on {
    border-color: #ffffff;
  }

  .sp-radio-inner {
    width: 6px;
    height: 6px;
    border-radius: 9999px;
    background: #ffffff;
  }

  .sp-card-body {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .sp-card-name {
    font-size: 13px;
    font-weight: 600;
    color: #ffffff;
    line-height: 1.3;
  }

  .sp-card-tagline {
    font-size: 11px;
    color: #666666;
  }

  .sp-badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 10px;
    font-weight: 500;
    border-radius: 9999px;
    padding: 2px 6px;
    margin-top: 4px;
  }

  .sp-badge--detected {
    color: #22c55e;
    background: rgba(34, 197, 94, 0.1);
    border: 1px solid rgba(34, 197, 94, 0.2);
  }

  .sp-badge--detecting {
    color: #666666;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  .sp-badge-dot {
    width: 5px;
    height: 5px;
    border-radius: 9999px;
    background: #22c55e;
    animation: sp-pulse 2s ease-in-out infinite;
  }

  .sp-badge-dot--shimmer {
    background: rgba(255, 255, 255, 0.2);
    animation: sp-shimmer 1.2s ease-in-out infinite;
  }

  @keyframes sp-pulse {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0.4; }
  }

  @keyframes sp-shimmer {
    0%, 100% { opacity: 0.2; }
    50%       { opacity: 0.6; }
  }

  .sp-actions {
    display: flex;
    justify-content: flex-end;
  }

  /* Shared button styles used across all steps */
  :global(.ob-btn) {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 10px 20px;
    border-radius: 10px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.15s ease, opacity 0.15s ease, transform 0.1s ease;
    border: none;
    user-select: none;
  }

  :global(.ob-btn:active) {
    transform: scale(0.98);
  }

  :global(.ob-btn:focus-visible) {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    outline-offset: 2px;
  }

  :global(.ob-btn--primary) {
    background: #ffffff;
    color: #0a0a0a;
  }

  :global(.ob-btn--primary:hover:not(:disabled)) {
    background: #e8e8e8;
  }

  :global(.ob-btn--primary:disabled) {
    opacity: 0.3;
    cursor: not-allowed;
  }

  :global(.ob-btn--ghost) {
    background: transparent;
    color: #a0a0a0;
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  :global(.ob-btn--ghost:hover) {
    background: rgba(255, 255, 255, 0.05);
    color: #ffffff;
  }

  @media (prefers-reduced-motion: reduce) {
    .sp-badge-dot,
    .sp-badge-dot--shimmer {
      animation: none;
    }
  }
</style>
