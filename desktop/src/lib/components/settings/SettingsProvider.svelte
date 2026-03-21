<script lang="ts">
  import { providers } from '$lib/api/client';
  import { PROVIDERS } from '$lib/onboarding/types';

  interface Props {
    selectedProvider: string;
    liveHealth: { provider: string; model: string } | null;
    liveHealthOffline: boolean;
    onSelectedProviderChange: (v: string) => void;
    onHealthRefresh: () => Promise<void>;
  }

  let {
    selectedProvider,
    liveHealth,
    liveHealthOffline,
    onSelectedProviderChange,
    onHealthRefresh,
  }: Props = $props();

  let apiKey            = $state('');
  let showApiKey        = $state(false);
  let testingConnection = $state(false);
  let connectionStatus  = $state<'idle' | 'ok' | 'error'>('idle');
  let connectionMessage = $state('');

  function providerMatchesHealth(metaId: string): boolean {
    if (!liveHealth) return false;
    const hp = liveHealth.provider.toLowerCase();
    if (metaId === 'ollama' && hp === 'ollama') return true;
    if (metaId === 'ollama-cloud' && (hp === 'ollama-cloud' || hp === 'ollama_cloud')) return true;
    return hp === metaId;
  }

  function liveHealthDisplayName(): string {
    if (!liveHealth) return '';
    const meta = PROVIDERS.find(p => providerMatchesHealth(p.id));
    return meta ? meta.name : liveHealth.provider;
  }

  async function testConnection() {
    if (!selectedProvider || !apiKey.trim()) return;
    testingConnection = true;
    connectionStatus  = 'idle';
    connectionMessage = '';
    try {
      await providers.connect(selectedProvider, apiKey.trim());
      connectionStatus  = 'ok';
      connectionMessage = 'Connection successful.';
      await onHealthRefresh();
    } catch (err) {
      connectionStatus  = 'error';
      connectionMessage = err instanceof Error ? err.message : 'Connection failed.';
    } finally {
      testingConnection = false;
    }
  }
</script>

<section class="sp-section">
  <h2 class="sp-section-title">Provider</h2>
  <p class="sp-section-desc">AI provider connection and credentials.</p>

  <!-- Current provider status -->
  <div class="sp-settings-group" style="margin-bottom: 20px;">
    <div class="sp-settings-item">
      <div class="sp-item-meta">
        <span class="sp-item-label">Connected providers</span>
      </div>
      <div class="sp-provider-badges">
        {#if liveHealthOffline}
          <span class="sp-live-health-pill sp-live-health-pill--offline">
            <span class="sp-live-dot sp-live-dot--red" aria-hidden="true"></span>
            Offline
          </span>
        {:else if liveHealth}
          <span class="sp-live-health-pill sp-live-health-pill--online">
            <span class="sp-live-dot sp-live-dot--green" aria-hidden="true"></span>
            {liveHealthDisplayName()}{liveHealth.model ? ` — ${liveHealth.model}` : ''}
          </span>
        {:else}
          <span class="sp-badge sp-badge--muted">None</span>
        {/if}
      </div>
    </div>
  </div>

  <!-- Provider selector (radio cards) -->
  <div class="sp-field-label-row">
    <span class="sp-field-label-text">Select provider</span>
  </div>
  <div class="sp-provider-grid">
    {#each PROVIDERS as meta (meta.id)}
      {@const isConnected = providerMatchesHealth(meta.id)}
      <label
        class="sp-provider-card"
        class:sp-provider-card--selected={selectedProvider === meta.id}
      >
        <input
          type="radio"
          name="provider"
          value={meta.id}
          checked={selectedProvider === meta.id}
          class="sp-sr-only"
          aria-label="Select {meta.name}"
          onchange={() => {
            onSelectedProviderChange(meta.id);
            if (meta.id === 'ollama-cloud' && !apiKey) {
              apiKey = 'https://ollama.com';
            }
          }}
        />
        <div class="sp-pcard-inner">
          <div class="sp-pcard-top">
            <span class="sp-pcard-name">{meta.name}</span>
            {#if isConnected}
              <span class="sp-pcard-dot sp-pcard-dot--green" aria-label="Connected"></span>
            {:else}
              <span class="sp-pcard-dot sp-pcard-dot--gray" aria-label="Not connected"></span>
            {/if}
          </div>
          <span class="sp-pcard-tag">{meta.tagline}</span>
        </div>
      </label>
    {/each}
  </div>

  <!-- API key (only for providers that require it) -->
  {#if PROVIDERS.find(p => p.id === selectedProvider)?.requiresKey}
    <div class="sp-settings-group" style="margin-top: 20px;">
      {#if selectedProvider === 'ollama-cloud'}
        <div class="sp-settings-item sp-settings-item--col">
          <div class="sp-item-meta">
            <span class="sp-item-label">Ollama endpoint URL</span>
            <span class="sp-item-hint">The URL of your remote Ollama instance (e.g. http://server:11434).</span>
          </div>
          <div class="sp-sk-input-wrap" style="margin-top: 8px;">
            <input
              type="text"
              class="sp-field-input sp-sk-mono"
              bind:value={apiKey}
              placeholder="http://your-server:11434"
              autocomplete="off"
              spellcheck={false}
              aria-label="Ollama cloud endpoint URL"
            />
          </div>
        </div>
      {:else}
        <div class="sp-settings-item sp-settings-item--col">
          <div class="sp-item-meta">
            <span class="sp-item-label">API key</span>
            <span class="sp-item-hint">Stored locally. Never transmitted to third parties.</span>
          </div>
          <div class="sp-sk-input-wrap" style="margin-top: 8px;">
            <input
              type={showApiKey ? 'text' : 'password'}
              class="sp-field-input sp-sk-mono"
              bind:value={apiKey}
              placeholder={PROVIDERS.find(p => p.id === selectedProvider)?.keyPlaceholder ?? ''}
              autocomplete="off"
              spellcheck={false}
              aria-label="API key"
            />
            <button
              type="button"
              class="sp-sk-eye"
              aria-label={showApiKey ? 'Hide API key' : 'Show API key'}
              onclick={() => { showApiKey = !showApiKey; }}
            >
              {#if showApiKey}
                <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"/></svg>
              {:else}
                <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/></svg>
              {/if}
            </button>
          </div>
        </div>
      {/if}
    </div>
  {/if}

  <!-- Test connection -->
  <div class="sp-save-row" style="margin-top: 20px;">
    <button
      type="button"
      class="sp-btn-ghost"
      onclick={testConnection}
      disabled={testingConnection || !selectedProvider}
    >
      {#if testingConnection}
        <span class="sp-spinner sp-spinner--dark" aria-hidden="true"></span>
        Testing…
      {:else}
        Test connection
      {/if}
    </button>

    {#if connectionStatus === 'ok'}
      <span class="sp-status-pill sp-status-pill--ok">
        <svg width="11" height="11" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M5 13l4 4L19 7"/></svg>
        {connectionMessage}
      </span>
    {:else if connectionStatus === 'error'}
      <span class="sp-status-pill sp-status-pill--error">{connectionMessage}</span>
    {/if}
  </div>
</section>

<style>
  .sp-section { max-width: 560px; }
  .sp-section-title { font-size: 18px; font-weight: 700; color: var(--text-primary); letter-spacing: -0.02em; margin: 0 0 4px; }
  .sp-section-desc { font-size: 13px; color: var(--text-tertiary); margin: 0 0 24px; }

  .sp-settings-group { background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.07); border-radius: 12px; overflow: hidden; }
  .sp-settings-item { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 13px 16px; min-height: 52px; }
  .sp-settings-item--col { flex-direction: column; align-items: flex-start; gap: 0; }
  .sp-item-meta { display: flex; flex-direction: column; gap: 2px; flex-shrink: 0; }
  .sp-item-label { font-size: 14px; color: rgba(255,255,255,0.88); font-weight: 450; white-space: nowrap; }
  .sp-item-hint { font-size: 11.5px; color: var(--text-tertiary); }

  .sp-field-input {
    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.09); border-radius: 8px;
    padding: 7px 12px; color: rgba(255,255,255,0.9); font-size: 13px; outline: none;
    transition: border-color 0.15s ease, background 0.15s ease; width: 220px; min-width: 0;
  }
  .sp-field-input::placeholder { color: rgba(255,255,255,0.2); }
  .sp-field-input:focus { border-color: rgba(255,255,255,0.22); background: rgba(255,255,255,0.07); }

  .sp-sk-input-wrap { position: relative; width: 100%; }
  .sp-sk-mono { font-family: var(--font-mono); font-size: 12px; width: 100%; padding-right: 40px; }
  .sp-sk-eye {
    position: absolute; right: 10px; top: 50%; transform: translateY(-50%);
    background: none; border: none; color: var(--text-tertiary); cursor: pointer;
    padding: 3px; display: flex; align-items: center; justify-content: center; transition: color 0.15s ease;
  }
  .sp-sk-eye:hover { color: rgba(255,255,255,0.6); }
  .sp-sk-eye:focus-visible { outline: 2px solid rgba(255,255,255,0.35); border-radius: 4px; }

  .sp-field-label-row { margin-bottom: 8px; }
  .sp-field-label-text { font-size: 12px; font-weight: 500; color: rgba(255,255,255,0.4); text-transform: uppercase; letter-spacing: 0.06em; }

  .sp-provider-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 8px; }
  .sp-provider-card { display: block; cursor: pointer; border-radius: 10px; border: 1px solid rgba(255,255,255,0.07); background: rgba(255,255,255,0.03); transition: border-color 0.15s ease, background 0.15s ease; }
  .sp-provider-card:hover { border-color: rgba(255,255,255,0.14); background: rgba(255,255,255,0.05); }
  .sp-provider-card--selected { border-color: rgba(59,130,246,0.45); background: rgba(59,130,246,0.08); }
  .sp-pcard-inner { padding: 12px 14px; display: flex; flex-direction: column; gap: 4px; }
  .sp-pcard-top { display: flex; align-items: center; justify-content: space-between; gap: 6px; }
  .sp-pcard-name { font-size: 13px; font-weight: 500; color: rgba(255,255,255,0.88); }
  .sp-pcard-tag { font-size: 11px; color: var(--text-tertiary); }
  .sp-pcard-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
  .sp-pcard-dot--green { background: var(--accent-success); box-shadow: 0 0 6px rgba(34,197,94,0.5); }
  .sp-pcard-dot--gray { background: rgba(255,255,255,0.15); }

  .sp-provider-badges { display: flex; gap: 6px; flex-wrap: wrap; }
  .sp-badge { display: inline-flex; align-items: center; padding: 3px 10px; border-radius: 9999px; font-size: 11.5px; font-weight: 500; }
  .sp-badge--muted { background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.07); color: var(--text-tertiary); }

  .sp-live-health-pill { display: inline-flex; align-items: center; gap: 6px; padding: 4px 12px; border-radius: 9999px; font-size: 12px; font-weight: 500; }
  .sp-live-health-pill--online { background: rgba(34,197,94,0.1); border: 1px solid rgba(34,197,94,0.22); color: rgba(34,197,94,0.95); }
  .sp-live-health-pill--offline { background: rgba(239,68,68,0.1); border: 1px solid rgba(239,68,68,0.22); color: rgba(239,68,68,0.9); }
  .sp-live-dot { width: 7px; height: 7px; border-radius: 50%; flex-shrink: 0; }
  .sp-live-dot--green { background: rgba(34,197,94,0.9); box-shadow: 0 0 4px rgba(34,197,94,0.5); }
  .sp-live-dot--red { background: rgba(239,68,68,0.9); box-shadow: 0 0 4px rgba(239,68,68,0.4); }

  .sp-btn-ghost {
    display: inline-flex; align-items: center; gap: 6px; padding: 7px 14px;
    background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 9999px;
    color: rgba(255,255,255,0.6); font-size: 13px; font-weight: 450; cursor: pointer;
    transition: background 0.13s ease, color 0.13s ease, border-color 0.13s ease;
  }
  .sp-btn-ghost:hover:not(:disabled) { background: rgba(255,255,255,0.07); color: rgba(255,255,255,0.85); border-color: rgba(255,255,255,0.13); }
  .sp-btn-ghost:disabled { opacity: 0.45; cursor: not-allowed; }
  .sp-btn-ghost:focus-visible { outline: 2px solid rgba(255,255,255,0.3); outline-offset: 2px; }

  .sp-save-row { display: flex; align-items: center; gap: 12px; }
  .sp-status-pill { display: inline-flex; align-items: center; gap: 5px; font-size: 12px; padding: 4px 10px; border-radius: 9999px; }
  .sp-status-pill--ok { background: rgba(34,197,94,0.1); border: 1px solid rgba(34,197,94,0.2); color: rgba(34,197,94,0.9); }
  .sp-status-pill--error { background: rgba(239,68,68,0.1); border: 1px solid rgba(239,68,68,0.2); color: rgba(239,68,68,0.9); }

  .sp-spinner { display: inline-block; width: 13px; height: 13px; border: 2px solid rgba(255,255,255,0.2); border-top-color: rgba(255,255,255,0.8); border-radius: 9999px; animation: sp-spin 0.6s linear infinite; flex-shrink: 0; }
  .sp-spinner--dark { border-color: rgba(255,255,255,0.12); border-top-color: rgba(255,255,255,0.5); }
  @keyframes sp-spin { to { transform: rotate(360deg); } }

  .sp-sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border-width: 0; }
  @media (prefers-reduced-motion: reduce) { .sp-spinner { animation: none; opacity: 0.5; } }
</style>
