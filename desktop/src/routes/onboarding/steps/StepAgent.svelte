<script lang="ts">
  import type { Provider, DetectionResult } from '$lib/onboarding/types';
  import { PROVIDERS } from '$lib/onboarding/types';
  import { validateApiKey } from '$lib/onboarding/validation';
  import { openUrl } from '@tauri-apps/plugin-opener';

  interface Props {
    provider: Provider | null;
    detectedProviders: DetectionResult;
    detecting: boolean;
    apiKey: string;
    agentName: string;
    onSelect: (p: Provider) => void;
    onNext: (opts: { provider: Provider; apiKey: string; agentName: string }) => void;
    onBack: () => void;
  }

  let {
    provider,
    detectedProviders,
    detecting,
    apiKey = $bindable(),
    agentName = $bindable(),
    onSelect,
    onNext,
    onBack,
  }: Props = $props();

  let showKey = $state(false);
  let validating = $state(false);
  let validationError = $state('');
  let canBypass = $state(false);
  let slowTimer: ReturnType<typeof setTimeout> | null = null;

  let meta = $derived(PROVIDERS.find((p) => p.id === provider) ?? null);
  let needsKey = $derived(meta?.requiresKey ?? false);
  let canSubmit = $derived(
    provider !== null &&
    (!needsKey || (apiKey.trim().length > 8 && !validating))
  );

  function isDetected(id: Provider): boolean {
    return (id === 'ollama' && detectedProviders.ollama) ||
           (id === 'lmstudio' && detectedProviders.lmstudio);
  }

  function handleProviderKeydown(e: KeyboardEvent) {
    const ids = PROVIDERS.map((p) => p.id);
    const idx = ids.indexOf(provider ?? ids[0]);

    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
      e.preventDefault();
      onSelect(ids[(idx + 1) % ids.length]);
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
      e.preventDefault();
      onSelect(ids[(idx - 1 + ids.length) % ids.length]);
    }
  }

  async function handleContinue() {
    if (!provider || !canSubmit) return;

    if (needsKey) {
      validationError = '';
      canBypass = false;
      validating = true;

      slowTimer = setTimeout(() => { canBypass = true; }, 3000);

      const result = await validateApiKey(provider, apiKey.trim());
      clearTimeout(slowTimer!);
      validating = false;

      if (!result.ok) {
        validationError = result.message;
        if (result.code === 'rate_limited' || result.code === 'timeout' || result.code === 'network_error') {
          canBypass = true;
        }
        return;
      }
    }

    onNext({
      provider,
      apiKey: apiKey.trim(),
      agentName: agentName.trim() || 'OSA Agent',
    });
  }

  function handleBypass() {
    if (!provider) return;
    onNext({ provider, apiKey: apiKey.trim(), agentName: agentName.trim() || 'OSA Agent' });
  }

  async function openDocs() {
    if (meta?.keyDocsUrl) {
      await openUrl(meta.keyDocsUrl);
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') onBack();
    if (e.key === 'Enter' && canSubmit && e.target instanceof HTMLInputElement) {
      void handleContinue();
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="sa-root">
  <div class="sa-heading">
    <h1 class="sa-title">Configure your agent</h1>
    <p class="sa-sub">Choose an AI provider and give your agent a name.</p>
  </div>

  <!-- Provider grid -->
  <div
    class="sa-grid"
    role="radiogroup"
    aria-label="AI provider"
    tabindex="0"
    onkeydown={handleProviderKeydown}
  >
    {#each PROVIDERS as pMeta}
      {@const detected = isDetected(pMeta.id)}
      {@const selected = provider === pMeta.id}
      <button
        class="sa-card"
        class:sa-card--selected={selected}
        role="radio"
        aria-checked={selected}
        aria-describedby="sa-desc-{pMeta.id}"
        onclick={() => onSelect(pMeta.id)}
        ondblclick={() => { onSelect(pMeta.id); void handleContinue(); }}
      >
        <div class="sa-radio" class:sa-radio--on={selected} aria-hidden="true">
          {#if selected}
            <div class="sa-radio-inner"></div>
          {/if}
        </div>
        <div class="sa-card-body">
          <span class="sa-card-name">{pMeta.name}</span>
          <span class="sa-card-tagline" id="sa-desc-{pMeta.id}">{pMeta.tagline}</span>
          {#if detecting && (pMeta.id === 'ollama' || pMeta.id === 'lmstudio')}
            <span class="sa-badge sa-badge--detecting" aria-label="Detecting...">
              <span class="sa-badge-dot sa-badge-dot--shimmer"></span>
              Detecting
            </span>
          {:else if detected}
            <span class="sa-badge sa-badge--detected">
              <span class="sa-badge-dot"></span>
              Detected
            </span>
          {/if}
        </div>
      </button>
    {/each}
  </div>

  <!-- API key (cloud providers only) -->
  {#if needsKey}
    <div class="sa-key-section">
      <div class="sa-field">
        <label for="sa-key" class="sa-label">API Key</label>
        <div class="sa-input-wrap">
          <input
            id="sa-key"
            type={showKey ? 'text' : 'password'}
            placeholder={meta?.keyPlaceholder ?? ''}
            bind:value={apiKey}
            autocomplete="off"
            spellcheck={false}
            class="sa-input"
            class:sa-input--error={validationError.length > 0}
            aria-describedby="sa-key-hint sa-key-error"
            aria-invalid={validationError.length > 0}
          />
          <button
            type="button"
            class="sa-toggle"
            aria-label={showKey ? 'Hide API key' : 'Show API key'}
            aria-controls="sa-key"
            onclick={() => showKey = !showKey}
          >
            {#if showKey}
              <svg width="15" height="15" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21" />
              </svg>
            {:else}
              <svg width="15" height="15" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
              </svg>
            {/if}
          </button>
        </div>
        {#if validationError}
          <p id="sa-key-error" class="sa-error" role="alert" aria-live="polite">{validationError}</p>
        {:else}
          <p id="sa-key-hint" class="sa-hint">Stored locally. Never transmitted without your knowledge.</p>
        {/if}
      </div>

      {#if meta?.keyDocsUrl}
        <button type="button" class="sa-docs-link" onclick={openDocs}>
          Where do I find this?
          <svg width="11" height="11" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
          </svg>
        </button>
      {/if}
    </div>
  {/if}

  <!-- Agent name -->
  <div class="sa-field">
    <label for="sa-agent-name" class="sa-label">Agent name</label>
    <input
      id="sa-agent-name"
      type="text"
      class="sa-input sa-input--text"
      placeholder="OSA Agent"
      bind:value={agentName}
      autocomplete="off"
      aria-describedby="sa-agent-hint"
    />
    <p id="sa-agent-hint" class="sa-hint">How you'll refer to your agent in conversations.</p>
  </div>

  <!-- Actions -->
  <div class="sa-actions">
    <button class="ob-btn ob-btn--ghost" onclick={onBack} aria-label="Back to workspace setup">
      Back
    </button>
    <div class="sa-actions-right">
      {#if canBypass && validationError}
        <button class="ob-btn ob-btn--ghost" onclick={handleBypass} style="font-size: 12px;">
          Continue anyway
        </button>
      {/if}
      <button
        class="ob-btn ob-btn--primary"
        disabled={!canSubmit}
        onclick={() => void handleContinue()}
        aria-label={needsKey ? 'Verify key and continue' : 'Continue to first task'}
      >
        {#if validating}
          <span class="sa-spinner" aria-hidden="true"></span>
          Verifying
        {:else if needsKey}
          Verify & Continue
          <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
          </svg>
        {:else}
          Continue
          <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
          </svg>
        {/if}
      </button>
    </div>
  </div>
</div>

<style>
  .sa-root {
    display: flex;
    flex-direction: column;
    gap: 16px;
    height: 100%;
  }

  .sa-title {
    font-size: 22px;
    font-weight: 800;
    color: #ffffff;
    letter-spacing: -0.03em;
    margin: 0 0 4px;
  }

  .sa-sub {
    font-size: 13px;
    color: #a0a0a0;
    margin: 0;
  }

  .sa-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 7px;
  }

  .sa-card {
    position: relative;
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 12px 12px;
    border-radius: 12px;
    text-align: left;
    cursor: pointer;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.07);
    transition: border-color 0.15s ease, background 0.15s ease, box-shadow 0.15s ease;
    color: inherit;
  }

  .sa-card:hover {
    background: rgba(255, 255, 255, 0.04);
    border-color: rgba(255, 255, 255, 0.12);
  }

  .sa-card:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    outline-offset: 2px;
  }

  .sa-card--selected {
    background: rgba(255, 255, 255, 0.05);
    border-color: rgba(255, 255, 255, 0.22);
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08);
  }

  .sa-radio {
    width: 15px;
    height: 15px;
    border-radius: 9999px;
    border: 2px solid rgba(255, 255, 255, 0.2);
    flex-shrink: 0;
    margin-top: 1px;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: border-color 0.15s ease;
  }

  .sa-radio--on {
    border-color: #ffffff;
  }

  .sa-radio-inner {
    width: 6px;
    height: 6px;
    border-radius: 9999px;
    background: #ffffff;
  }

  .sa-card-body {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .sa-card-name {
    font-size: 12px;
    font-weight: 600;
    color: #ffffff;
    line-height: 1.3;
  }

  .sa-card-tagline {
    font-size: 10px;
    color: #666666;
  }

  .sa-badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 10px;
    font-weight: 500;
    border-radius: 9999px;
    padding: 2px 6px;
    margin-top: 3px;
  }

  .sa-badge--detected {
    color: #22c55e;
    background: rgba(34, 197, 94, 0.1);
    border: 1px solid rgba(34, 197, 94, 0.2);
  }

  .sa-badge--detecting {
    color: #666666;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  .sa-badge-dot {
    width: 5px;
    height: 5px;
    border-radius: 9999px;
    background: #22c55e;
    animation: sa-pulse 2s ease-in-out infinite;
  }

  .sa-badge-dot--shimmer {
    background: rgba(255, 255, 255, 0.2);
    animation: sa-shimmer 1.2s ease-in-out infinite;
  }

  @keyframes sa-pulse {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0.4; }
  }

  @keyframes sa-shimmer {
    0%, 100% { opacity: 0.2; }
    50%       { opacity: 0.6; }
  }

  .sa-key-section {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .sa-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .sa-label {
    font-size: 12px;
    font-weight: 500;
    color: #a0a0a0;
    letter-spacing: 0.02em;
  }

  .sa-input-wrap {
    position: relative;
  }

  .sa-input {
    width: 100%;
    padding: 10px 42px 10px 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    color: #ffffff;
    font-size: 13px;
    font-family: 'SF Mono', 'Fira Code', monospace;
    outline: none;
    transition: border-color 0.15s ease, background 0.15s ease;
    box-sizing: border-box;
  }

  .sa-input--text {
    font-family: inherit;
    padding: 10px 14px;
  }

  .sa-input::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  .sa-input:focus {
    border-color: rgba(255, 255, 255, 0.25);
    background: rgba(255, 255, 255, 0.06);
  }

  .sa-input--error {
    border-color: rgba(239, 68, 68, 0.5);
    background: rgba(239, 68, 68, 0.04);
  }

  .sa-toggle {
    position: absolute;
    right: 12px;
    top: 50%;
    transform: translateY(-50%);
    background: none;
    border: none;
    color: #666666;
    cursor: pointer;
    padding: 2px;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color 0.15s ease;
  }

  .sa-toggle:hover {
    color: #a0a0a0;
  }

  .sa-toggle:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    border-radius: 4px;
  }

  .sa-hint {
    font-size: 11px;
    color: #555555;
    margin: 0;
  }

  .sa-error {
    font-size: 12px;
    color: #ef4444;
    margin: 0;
  }

  .sa-docs-link {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 12px;
    color: #a0a0a0;
    background: none;
    border: none;
    cursor: pointer;
    padding: 0;
    text-decoration: underline;
    text-underline-offset: 2px;
    transition: color 0.15s ease;
  }

  .sa-docs-link:hover {
    color: #ffffff;
  }

  .sa-docs-link:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    border-radius: 2px;
  }

  .sa-actions {
    margin-top: auto;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .sa-actions-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .sa-spinner {
    width: 13px;
    height: 13px;
    border: 2px solid rgba(0, 0, 0, 0.2);
    border-top-color: #0a0a0a;
    border-radius: 9999px;
    animation: sa-spin 0.6s linear infinite;
  }

  @keyframes sa-spin {
    to { transform: rotate(360deg); }
  }

  @media (prefers-reduced-motion: reduce) {
    .sa-badge-dot,
    .sa-badge-dot--shimmer,
    .sa-spinner {
      animation: none;
    }

    .sa-spinner {
      opacity: 0.5;
      border-top-color: transparent;
    }
  }
</style>
