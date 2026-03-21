<script lang="ts">
  import { openUrl } from '@tauri-apps/plugin-opener';
  import type { HealthResponse } from '$lib/api/types';

  interface Props {
    appVersion: string;
    backendVersion: string;
    healthData: HealthResponse | null;
  }

  let { appVersion, backendVersion, healthData }: Props = $props();

  async function openLink(url: string) {
    try {
      await openUrl(url);
    } catch {
      window.open(url, '_blank');
    }
  }
</script>

<section class="sab-section">
  <h2 class="sab-section-title">About</h2>
  <p class="sab-section-desc">Version information and resources.</p>

  <div class="sab-settings-group">
    <div class="sab-settings-item">
      <span class="sab-item-label">App version</span>
      <span class="sab-field-readonly">v{appVersion}</span>
    </div>

    <div class="sab-item-divider"></div>

    <div class="sab-settings-item">
      <span class="sab-item-label">Backend version</span>
      <span class="sab-field-readonly">
        {#if backendVersion === 'offline'}
          <span class="sab-status-dot sab-status-dot--error"></span> Offline
        {:else}
          <span class="sab-status-dot sab-status-dot--ok"></span> v{backendVersion}
        {/if}
      </span>
    </div>

    <div class="sab-item-divider"></div>

    <div class="sab-settings-item">
      <span class="sab-item-label">Agent status</span>
      <span class="sab-field-readonly">
        {#if healthData?.agents_active != null}
          {healthData.agents_active} active
        {:else}
          —
        {/if}
      </span>
    </div>
  </div>

  <div class="sab-canopy-section">
    <p class="sab-canopy-title">Workspace Protocol</p>
    <p class="sab-canopy-desc">Powered by Canopy — the open workspace protocol for AI agents.</p>
  </div>

  <div class="sab-link-list">
    <button type="button" class="sab-link-btn" onclick={() => openLink('https://github.com/robertohluna/osa-desktop')}>
      <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4"/></svg>
      GitHub
      <svg width="10" height="10" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true" class="sab-ext-icon"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg>
    </button>
    <button type="button" class="sab-link-btn" onclick={() => openLink('https://docs.osa.dev')}>
      <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M12 6.042A8.967 8.967 0 006 3.75c-1.052 0-2.062.18-3 .512v14.25A8.987 8.987 0 016 18c2.305 0 4.408.867 6 2.292m0-14.25a8.966 8.966 0 016-2.292c1.052 0 2.062.18 3 .512v14.25A8.987 8.987 0 0018 18a8.967 8.967 0 00-6 2.292m0-14.25v14.25"/></svg>
      Documentation
      <svg width="10" height="10" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true" class="sab-ext-icon"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg>
    </button>
    <button type="button" class="sab-link-btn" onclick={() => openLink('https://github.com/robertohluna/osa-desktop/issues/new')}>
      <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M12 9v3.75m9-.75a9 9 0 11-18 0 9 9 0 0118 0zm-9 3.75h.008v.008H12v-.008z"/></svg>
      Report an issue
      <svg width="10" height="10" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true" class="sab-ext-icon"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg>
    </button>
  </div>
</section>

<style>
  .sab-section { max-width: 560px; }

  .sab-section-title {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
    margin: 0 0 4px;
  }

  .sab-section-desc {
    font-size: 13px;
    color: var(--text-tertiary);
    margin: 0 0 24px;
  }

  .sab-settings-group {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 12px;
    overflow: hidden;
  }

  .sab-settings-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 13px 16px;
    min-height: 52px;
  }

  .sab-item-divider {
    height: 1px;
    background: rgba(255, 255, 255, 0.06);
  }

  .sab-item-label {
    font-size: 14px;
    color: rgba(255, 255, 255, 0.88);
    font-weight: 450;
    white-space: nowrap;
  }

  .sab-field-readonly {
    font-size: 13px;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .sab-status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .sab-status-dot--ok    { background: var(--accent-success); }
  .sab-status-dot--error { background: var(--accent-error); }

  .sab-link-list {
    margin-top: 20px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .sab-link-btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 9px 12px;
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.55);
    font-size: 13px;
    font-weight: 450;
    cursor: pointer;
    border-radius: 8px;
    text-align: left;
    transition: background 0.13s ease, color 0.13s ease;
    width: 100%;
  }

  .sab-link-btn:hover {
    background: rgba(255, 255, 255, 0.04);
    color: rgba(255, 255, 255, 0.85);
  }

  .sab-link-btn:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.3);
    outline-offset: 2px;
  }

  .sab-ext-icon {
    opacity: 0.4;
    margin-left: auto;
  }

  .sab-canopy-section {
    margin-top: 28px;
    padding-top: 20px;
    border-top: 1px solid rgba(255, 255, 255, 0.06);
  }

  .sab-canopy-title {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.28);
    margin: 0 0 4px;
  }

  .sab-canopy-desc {
    font-size: 12px;
    color: var(--text-tertiary);
    margin: 0;
    line-height: 1.5;
  }
</style>
