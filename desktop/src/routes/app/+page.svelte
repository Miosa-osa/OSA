<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { dashboardStore } from '$lib/stores/dashboard.svelte';
  import { restartBackend } from '$lib/utils/backend';
  import SystemHealthBar from '$lib/components/dashboard/SystemHealthBar.svelte';
  import KpiGrid from '$lib/components/dashboard/KpiGrid.svelte';
  import RecentActivityFeed from '$lib/components/dashboard/RecentActivityFeed.svelte';
  import ActiveAgentsPanel from '$lib/components/dashboard/ActiveAgentsPanel.svelte';

  let cleanup: (() => void) | undefined;
  let restarting = $state(false);

  onMount(() => {
    cleanup = dashboardStore.startAutoRefresh(30_000);
  });

  onDestroy(() => {
    cleanup?.();
  });

  async function handleRestart() {
    restarting = true;
    try {
      await restartBackend();
      // Give the backend a moment to come up before retrying.
      await new Promise((r) => setTimeout(r, 2000));
      await dashboardStore.load();
    } finally {
      restarting = false;
    }
  }
</script>

<svelte:head>
  <title>Dashboard — OSA</title>
</svelte:head>

<section class="dash" aria-label="Dashboard">
  {#if dashboardStore.isOffline && !dashboardStore.loading}
    <!-- ── Offline welcome state ─────────────────────────────────────────── -->
    <div class="dash-offline-wrap">
      <div class="dash-welcome" role="status" aria-live="polite">
        <!-- Gradient mark -->
        <div class="dash-mark" aria-hidden="true">
          <svg width="40" height="40" viewBox="0 0 40 40" fill="none">
            <defs>
              <linearGradient id="mark-grad" x1="0" y1="0" x2="40" y2="40" gradientUnits="userSpaceOnUse">
                <stop offset="0%" stop-color="#818cf8" />
                <stop offset="100%" stop-color="#6366f1" />
              </linearGradient>
            </defs>
            <rect width="40" height="40" rx="10" fill="url(#mark-grad)" opacity="0.15" />
            <path d="M20 8l8 14H12L20 8z M20 32l-8-14h16L20 32z" fill="url(#mark-grad)" />
          </svg>
        </div>

        <h2 class="dash-welcome-title">Welcome to OSA</h2>
        <p class="dash-welcome-body">
          Your agent backend is starting up. Once connected, you'll see system
          metrics, recent activity, and active agents here.
        </p>

        <button
          class="dash-start-btn"
          onclick={handleRestart}
          disabled={restarting}
          aria-label="Start backend"
        >
          {#if restarting}
            <span class="dash-start-spinner" aria-hidden="true"></span>
            Starting…
          {:else}
            Start Backend
          {/if}
        </button>

        <div class="dash-offline-badge" aria-label="Connection status: offline">
          <span class="dash-offline-dot" aria-hidden="true"></span>
          Offline — Waiting for backend on port 9089
        </div>
      </div>
    </div>

  {:else}
    <!-- ── Normal dashboard layout ──────────────────────────────────────── -->
    <SystemHealthBar
      health={dashboardStore.systemHealth}
      uptimeSeconds={dashboardStore.kpis.uptime_seconds}
      offline={dashboardStore.isOffline}
    />

    <KpiGrid kpis={dashboardStore.kpis} loading={dashboardStore.loading} />

    {#if !dashboardStore.loading}
      <div class="dash-panels">
        <div class="dash-feed">
          <RecentActivityFeed activities={dashboardStore.recentActivity} />
        </div>
        <div class="dash-agents">
          <ActiveAgentsPanel
            agents={dashboardStore.activeAgents}
            agentsTotal={dashboardStore.kpis.agents_total}
          />
        </div>
      </div>
    {/if}

    {#if dashboardStore.error && !dashboardStore.isOffline}
      <p class="dash-error" role="alert">{dashboardStore.error}</p>
    {/if}
  {/if}
</section>

<style>
  .dash {
    display: flex;
    flex-direction: column;
    gap: 16px;
    padding: 16px;
    height: 100%;
    box-sizing: border-box;
    overflow-y: auto;
  }

  /* ── Offline / welcome state ──────────────────────────────────────────── */
  .dash-offline-wrap {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 32px 16px;
  }

  .dash-welcome {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 16px;
    max-width: 400px;
    width: 100%;
    padding: 40px 32px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 16px;
    text-align: center;
  }

  .dash-mark {
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .dash-welcome-title {
    font-size: 20px;
    font-weight: 700;
    color: var(--text-primary);
    margin: 0;
    letter-spacing: -0.3px;
  }

  .dash-welcome-body {
    font-size: 13px;
    line-height: 1.6;
    color: var(--text-secondary);
    margin: 0;
  }

  .dash-start-btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 9px 20px;
    border-radius: 8px;
    border: none;
    background: var(--accent-primary, #6366f1);
    color: #fff;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: opacity 0.15s ease, transform 0.1s ease;
    margin-top: 4px;
  }

  .dash-start-btn:hover:not(:disabled) {
    opacity: 0.88;
    transform: translateY(-1px);
  }

  .dash-start-btn:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }

  .dash-start-spinner {
    width: 12px;
    height: 12px;
    border: 2px solid rgba(255, 255, 255, 0.3);
    border-top-color: #fff;
    border-radius: 50%;
    animation: dash-spin 0.7s linear infinite;
    flex-shrink: 0;
  }

  @keyframes dash-spin {
    to { transform: rotate(360deg); }
  }

  .dash-offline-badge {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 5px 12px;
    border-radius: 999px;
    background: rgba(239, 68, 68, 0.08);
    border: 1px solid rgba(239, 68, 68, 0.18);
    font-size: 11px;
    color: var(--accent-error, #ef4444);
    letter-spacing: 0.01em;
    margin-top: 4px;
  }

  .dash-offline-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--accent-error, #ef4444);
    flex-shrink: 0;
    animation: dash-pulse 2s ease-in-out infinite;
  }

  @keyframes dash-pulse {
    0%, 100% { opacity: 1; transform: scale(1); }
    50%       { opacity: 0.4; transform: scale(0.75); }
  }

  /* ── Normal layout ────────────────────────────────────────────────────── */
  .dash-panels {
    display: grid;
    grid-template-columns: 3fr 2fr;
    gap: 12px;
    min-height: 0;
  }

  .dash-feed {
    min-width: 0;
  }

  .dash-agents {
    min-width: 0;
  }

  .dash-error {
    font-size: 12px;
    color: var(--accent-error);
    text-align: center;
    margin: 0;
    padding: 8px;
  }

  @media (max-width: 768px) {
    .dash-panels {
      grid-template-columns: 1fr;
    }
  }
</style>
