<script lang="ts">
  import type { Provider } from '$lib/onboarding/types';
  import { PROVIDERS } from '$lib/onboarding/types';
  import { validateApiKey } from '$lib/onboarding/validation';
  import { openUrl } from '@tauri-apps/plugin-opener';

  interface Props {
    provider: Provider | null;
    apiKey: string;
    onNext: () => void;
    onBack: () => void;
  }

  let { provider, apiKey = $bindable(), onNext, onBack }: Props = $props();

  let showKey = $state(false);
  let validating = $state(false);
  let validationError = $state('');
  let canBypass = $state(false); // shown after timeout or soft errors
  let slowTimer: ReturnType<typeof setTimeout> | null = null;

  let meta = $derived(PROVIDERS.find((p) => p.id === provider) ?? null);
  let canSubmit = $derived(apiKey.trim().length > 8 && !validating);

  async function handleContinue() {
    if (!provider || !meta) return;
    validationError = '';
    canBypass = false;
    validating = true;

    // Show bypass option after 3 seconds
    slowTimer = setTimeout(() => { canBypass = true; }, 3000);

    const result = await validateApiKey(provider, apiKey.trim());
    clearTimeout(slowTimer!);
    validating = false;

    if (result.ok) {
      onNext();
    } else {
      validationError = result.message;
      // Soft errors get bypass option immediately
      if (result.code === 'rate_limited' || result.code === 'timeout' || result.code === 'network_error') {
        canBypass = true;
      }
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' && canSubmit) handleContinue();
    if (e.key === 'Escape') onBack();
  }

  async function openDocs() {
    if (meta?.keyDocsUrl) {
      await openUrl(meta.keyDocsUrl);
    }
  }
</script>

<div class="sk-root">
  <div class="sk-heading">
    <h1 class="sk-title">{meta?.name ?? ''} API Key</h1>
    <p class="sk-sub">Stored locally in your system keychain. Never transmitted.</p>
  </div>

  <div class="sk-field">
    <label for="sk-input" class="sk-label">API Key</label>
    <div class="sk-input-wrap">
      <input
        id="sk-input"
        type={showKey ? 'text' : 'password'}
        placeholder={meta?.keyPlaceholder ?? ''}
        bind:value={apiKey}
        autocomplete="off"
        spellcheck={false}
        aria-describedby="sk-hint sk-error"
        aria-invalid={validationError.length > 0}
        onkeydown={handleKeydown}
        class="sk-input"
        class:sk-input--error={validationError.length > 0}
      />
      <button
        type="button"
        class="sk-toggle"
        aria-label={showKey ? 'Hide API key' : 'Show API key'}
        aria-controls="sk-input"
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
      <p id="sk-error" class="sk-error" role="alert" aria-live="polite">{validationError}</p>
    {:else}
      <p id="sk-hint" class="sk-hint">Paste your key from the provider dashboard.</p>
    {/if}
  </div>

  {#if meta?.keyDocsUrl}
    <button type="button" class="sk-docs-link" onclick={openDocs}>
      Where do I find this?
      <svg width="11" height="11" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
      </svg>
    </button>
  {/if}

  <div class="sk-actions">
    <button class="ob-btn ob-btn--ghost" onclick={onBack}>
      Back
    </button>

    <div class="sk-actions-right">
      {#if canBypass && validationError}
        <button class="ob-btn ob-btn--ghost" onclick={onNext} style="font-size: 12px;">
          Continue anyway
        </button>
      {/if}

      <button
        class="ob-btn ob-btn--primary"
        disabled={!canSubmit}
        onclick={handleContinue}
      >
        {#if validating}
          <span class="sk-spinner" aria-hidden="true"></span>
          Verifying
        {:else}
          Verify & Continue
          <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
          </svg>
        {/if}
      </button>
    </div>
  </div>
</div>

<style>
  .sk-root {
    display: flex;
    flex-direction: column;
    gap: 20px;
    height: 100%;
  }

  .sk-title {
    font-size: 22px;
    font-weight: 800;
    color: #ffffff;
    letter-spacing: -0.03em;
    margin: 0 0 4px;
  }

  .sk-sub {
    font-size: 13px;
    color: #a0a0a0;
    margin: 0;
  }

  .sk-field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .sk-label {
    font-size: 12px;
    font-weight: 500;
    color: #a0a0a0;
    letter-spacing: 0.02em;
  }

  .sk-input-wrap {
    position: relative;
  }

  .sk-input {
    width: 100%;
    padding: 11px 42px 11px 14px;
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

  .sk-input::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  .sk-input:focus {
    border-color: rgba(255, 255, 255, 0.25);
    background: rgba(255, 255, 255, 0.06);
  }

  .sk-input--error {
    border-color: rgba(239, 68, 68, 0.5);
    background: rgba(239, 68, 68, 0.04);
  }

  .sk-toggle {
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

  .sk-toggle:hover {
    color: #a0a0a0;
  }

  .sk-toggle:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    border-radius: 4px;
  }

  .sk-error {
    font-size: 12px;
    color: #ef4444;
    margin: 0;
  }

  .sk-hint {
    font-size: 12px;
    color: #666666;
    margin: 0;
  }

  .sk-docs-link {
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

  .sk-docs-link:hover {
    color: #ffffff;
  }

  .sk-docs-link:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    border-radius: 2px;
  }

  .sk-actions {
    margin-top: auto;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .sk-actions-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .sk-spinner {
    width: 13px;
    height: 13px;
    border: 2px solid rgba(0, 0, 0, 0.2);
    border-top-color: #0a0a0a;
    border-radius: 9999px;
    animation: sk-spin 0.6s linear infinite;
  }

  @keyframes sk-spin {
    to { transform: rotate(360deg); }
  }

  @media (prefers-reduced-motion: reduce) {
    .sk-spinner {
      animation: none;
      border-top-color: transparent;
      opacity: 0.5;
    }
  }
</style>
