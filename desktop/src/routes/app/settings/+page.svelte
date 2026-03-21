<script lang="ts">
  import { onMount } from 'svelte';
  import { getVersion } from '@tauri-apps/api/app';
  import { health, settings } from '$lib/api/client';
  import type { Settings, HealthResponse } from '$lib/api/types';

  import SettingsGeneral     from '$lib/components/settings/SettingsGeneral.svelte';
  import SettingsProvider    from '$lib/components/settings/SettingsProvider.svelte';
  import SettingsVoice       from '$lib/components/settings/SettingsVoice.svelte';
  import SettingsPermissions from '$lib/components/settings/SettingsPermissions.svelte';
  import SettingsAdvanced    from '$lib/components/settings/SettingsAdvanced.svelte';
  import SettingsAbout       from '$lib/components/settings/SettingsAbout.svelte';
  import SettingsWorkspace   from '$lib/components/settings/SettingsWorkspace.svelte';
  import ConfigHistory       from '$lib/components/settings/ConfigHistory.svelte';

  // ── Tab definitions ──────────────────────────────────────────────────────────

  type TabId = 'general' | 'provider' | 'workspace' | 'voice' | 'permissions' | 'advanced' | 'history' | 'about';

  interface Tab { id: TabId; label: string; icon: string; }

  const TABS: Tab[] = [
    { id: 'general',     label: 'General',     icon: 'sliders'   },
    { id: 'provider',    label: 'Provider',     icon: 'cpu'       },
    { id: 'workspace',   label: 'Workspace',    icon: 'folder'    },
    { id: 'voice',       label: 'Voice',        icon: 'mic'       },
    { id: 'permissions', label: 'Permissions',  icon: 'shield'    },
    { id: 'advanced',    label: 'Advanced',     icon: 'terminal'  },
    { id: 'history',     label: 'History',      icon: 'clock'     },
    { id: 'about',       label: 'About',        icon: 'info'      },
  ];

  // ── Shared state ─────────────────────────────────────────────────────────────

  let activeTab = $state<TabId>('general');

  // General
  let agentName  = $state('OSA Agent');
  let workingDir = $state('');
  let saving     = $state(false);
  let saveSuccess = $state(false);

  // Provider
  let selectedProvider  = $state('');
  let liveHealth        = $state<{ provider: string; model: string } | null>(null);
  let liveHealthOffline = $state(false);

  // Advanced / About
  let contextWindow  = $state<number | null>(null);
  let appVersion     = $state('');
  let backendVersion = $state('');
  let healthData     = $state<HealthResponse | null>(null);

  // ── Init ─────────────────────────────────────────────────────────────────────

  onMount(async () => {
    await Promise.allSettled([
      loadSettings(),
      loadAppVersion(),
      loadBackendHealth(),
    ]);
  });

  async function loadSettings() {
    try {
      const s: Settings = await settings.get();
      selectedProvider = s.provider ?? '';
      workingDir       = s.working_dir ?? '';
    } catch {
      // backend may be offline — fail silently
    }
  }

  async function loadAppVersion() {
    try { appVersion = await getVersion(); }
    catch { appVersion = '—'; }
  }

  async function loadBackendHealth() {
    try {
      healthData     = await health.get();
      backendVersion = healthData?.version ?? '—';
      contextWindow  = healthData?.context_window ?? null;
      if (healthData?.status === 'ok' && healthData.provider) {
        liveHealth        = { provider: healthData.provider, model: healthData.model ?? '' };
        liveHealthOffline = false;
      } else {
        liveHealth        = null;
        liveHealthOffline = false;
      }
    } catch {
      backendVersion    = 'offline';
      liveHealth        = null;
      liveHealthOffline = true;
    }
  }

  // ── Shared save ───────────────────────────────────────────────────────────────

  async function saveSettings() {
    saving      = true;
    saveSuccess = false;
    try {
      await settings.update({ working_dir: workingDir });
      saveSuccess = true;
      setTimeout(() => { saveSuccess = false; }, 2000);
    } catch {
      // status indicator handles this
    } finally {
      saving = false;
    }
  }
</script>

<div class="settings-root">
  <!-- Left tab rail -->
  <nav class="tab-rail" aria-label="Settings sections">
    <div class="rail-header">
      <span class="rail-title">Settings</span>
    </div>

    <ul class="rail-list" role="tablist">
      {#each TABS as tab (tab.id)}
        <li role="none">
          <button
            role="tab"
            aria-selected={activeTab === tab.id}
            aria-controls="settings-panel"
            class="rail-item"
            class:rail-item--active={activeTab === tab.id}
            onclick={() => { activeTab = tab.id; }}
          >
            <span class="rail-icon" aria-hidden="true">
              {#if tab.icon === 'sliders'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M10.5 6h9.75M10.5 6a1.5 1.5 0 11-3 0m3 0a1.5 1.5 0 10-3 0M3.75 6H7.5m3 12h9.75m-9.75 0a1.5 1.5 0 01-3 0m3 0a1.5 1.5 0 00-3 0m-3.75 0H7.5m9-6h3.75m-3.75 0a1.5 1.5 0 01-3 0m3 0a1.5 1.5 0 00-3 0m-9.75 0h9.75"/></svg>
              {:else if tab.icon === 'cpu'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12H3m18 0h-1.5m-15 3.75H3m18 0h-1.5M8.25 19.5V21M12 3v1.5m0 15V21m3.75-18v1.5m0 15V21m-9-1.5h10.5a2.25 2.25 0 002.25-2.25V6.75a2.25 2.25 0 00-2.25-2.25H6.75A2.25 2.25 0 004.5 6.75v10.5a2.25 2.25 0 002.25 2.25zm.75-12h9v9h-9v-9z"/></svg>
              {:else if tab.icon === 'folder'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z"/></svg>
              {:else if tab.icon === 'mic'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M12 1a3 3 0 00-3 3v8a3 3 0 006 0V4a3 3 0 00-3-3z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M19 10v2a7 7 0 01-14 0v-2"/><line x1="12" y1="19" x2="12" y2="23" stroke-width="1.75" stroke-linecap="round"/><line x1="8" y1="23" x2="16" y2="23" stroke-width="1.75" stroke-linecap="round"/></svg>
              {:else if tab.icon === 'shield'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z"/></svg>
              {:else if tab.icon === 'terminal'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M6.75 7.5l3 2.25-3 2.25m4.5 0h3m-9 8.25h13.5A2.25 2.25 0 0021 18V6a2.25 2.25 0 00-2.25-2.25H5.25A2.25 2.25 0 003 6v12a2.25 2.25 0 002.25 2.25z"/></svg>
              {:else if tab.icon === 'clock'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
              {:else if tab.icon === 'info'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M11.25 11.25l.041-.02a.75.75 0 011.063.852l-.708 2.836a.75.75 0 001.063.853l.041-.021M21 12a9 9 0 11-18 0 9 9 0 0118 0zm-9-3.75h.008v.008H12V8.25z"/></svg>
              {/if}
            </span>
            <span class="rail-label">{tab.label}</span>
          </button>
        </li>
      {/each}
    </ul>
  </nav>

  <!-- Right content panel -->
  <div
    id="settings-panel"
    role="tabpanel"
    class="content-panel"
    aria-label="{TABS.find(t => t.id === activeTab)?.label} settings"
  >
    <div class="panel-scroll">
      {#if activeTab === 'general'}
        <SettingsGeneral
          {agentName}
          {workingDir}
          {saving}
          {saveSuccess}
          onAgentNameChange={(v) => { agentName = v; }}
          onWorkingDirChange={(v) => { workingDir = v; }}
          onSave={saveSettings}
        />
      {:else if activeTab === 'provider'}
        <SettingsProvider
          {selectedProvider}
          {liveHealth}
          {liveHealthOffline}
          onSelectedProviderChange={(v) => { selectedProvider = v; }}
          onHealthRefresh={loadBackendHealth}
        />
      {:else if activeTab === 'workspace'}
        <SettingsWorkspace />
      {:else if activeTab === 'voice'}
        <SettingsVoice />
      {:else if activeTab === 'permissions'}
        <SettingsPermissions />
      {:else if activeTab === 'advanced'}
        <SettingsAdvanced {contextWindow} />
      {:else if activeTab === 'history'}
        <section class="history-section">
          <h2 class="history-title">Config History</h2>
          <p class="history-desc">Track and rollback configuration changes.</p>
          <ConfigHistory entityType="system" entityId="global" />
        </section>
      {:else if activeTab === 'about'}
        <SettingsAbout {appVersion} {backendVersion} {healthData} />
      {/if}
    </div>
  </div>
</div>

<style>
  .settings-root {
    display: flex;
    flex: 1;
    min-height: 0;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  /* ── Tab rail ─────────────────────────────────────────────────────────────── */

  .tab-rail {
    width: 188px;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    background: rgba(255, 255, 255, 0.02);
    border-right: 1px solid rgba(255, 255, 255, 0.06);
    padding: 20px 10px;
    overflow-y: auto;
  }

  .rail-header { padding: 0 6px 16px; }

  .rail-title {
    font-size: 11px;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.3);
    text-transform: uppercase;
    letter-spacing: 0.08em;
  }

  .rail-list {
    list-style: none;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .rail-item {
    display: flex;
    align-items: center;
    gap: 9px;
    width: 100%;
    padding: 8px 10px;
    background: none;
    border: none;
    border-radius: var(--radius-sm);
    color: rgba(255, 255, 255, 0.45);
    font-size: 13px;
    font-weight: 450;
    cursor: pointer;
    transition: background 0.13s ease, color 0.13s ease;
    text-align: left;
  }

  .rail-item:hover {
    background: rgba(255, 255, 255, 0.05);
    color: rgba(255, 255, 255, 0.75);
  }

  .rail-item--active {
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.92);
    font-weight: 500;
  }

  .rail-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    opacity: 0.85;
  }

  .rail-label { flex: 1; min-width: 0; }

  /* ── Content panel ───────────────────────────────────────────────────────── */

  .content-panel {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  .panel-scroll {
    flex: 1;
    overflow-y: auto;
    padding: 32px 40px 48px;
  }

  /* ── History section (inline — not a separate component) ─────────────────── */

  .history-section { max-width: 560px; }

  .history-title {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
    margin: 0 0 4px;
  }

  .history-desc {
    font-size: 13px;
    color: var(--text-tertiary);
    margin: 0 0 24px;
  }
</style>
