<script lang="ts">
  import { onMount } from 'svelte';
  import ServiceScanner from '$lib/components/connectors/ServiceScanner.svelte';
  import ConnectorCard  from '$lib/components/connectors/ConnectorCard.svelte';
  import ConnectorForm  from '$lib/components/connectors/ConnectorForm.svelte';
  import type { Connector, DetectedService, ConnectorFormValues } from '$lib/components/connectors/types';

  // ── Constants ────────────────────────────────────────────────────────────────

  const STORAGE_KEY = 'osa-connectors';

  // ── State ────────────────────────────────────────────────────────────────────

  let connectors   = $state<Connector[]>([]);
  let showAddModal = $state(false);

  // Scanner component ref for triggering scan
  let scanner: ServiceScanner | undefined = $state();

  let addedUrls = $derived(connectors.map((c) => c.url));

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  onMount(() => {
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      if (stored) connectors = JSON.parse(stored);
    } catch { /* */ }

    scanner?.scanServices();
  });

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function saveConnectors() {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(connectors));
  }

  function makeId() {
    return `${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
  }

  // ── Handlers ─────────────────────────────────────────────────────────────────

  function handleAddFromDetected(service: DetectedService) {
    if (connectors.some((c) => c.url === service.url)) return;

    connectors = [...connectors, {
      id:          makeId(),
      name:        service.name,
      type:        service.type,
      status:      'connected',
      url:         service.url,
      description: `Auto-detected on port ${service.port}`,
      lastSeen:    new Date().toISOString(),
    }];
    saveConnectors();
  }

  function handleFormSubmit(values: ConnectorFormValues) {
    connectors = [...connectors, {
      id:          makeId(),
      ...values,
      status:      'disconnected',
      lastSeen:    null,
    }];
    saveConnectors();
    showAddModal = false;
  }

  function handleConnect(connector: Connector) {
    const message = `Connect to the service "${connector.name}" at ${connector.url}. Analyze its API, understand its structure, and tell me how to integrate with it.`;
    if (typeof window !== 'undefined') {
      window.dispatchEvent(new CustomEvent('osa:send-message', { detail: { message } }));
    }
  }

  function handleRemove(id: string) {
    connectors = connectors.filter((c) => c.id !== id);
    saveConnectors();
  }
</script>

<div class="cp-page">
  <!-- Header -->
  <header class="cp-header">
    <div class="cp-header-text">
      <h1 class="cp-title">OS Connectors</h1>
      <p class="cp-subtitle">Connect OSA to your local services, repos, and applications.</p>
    </div>
    <div class="cp-header-actions">
      <button
        class="cp-btn cp-btn--ghost"
        onclick={() => scanner?.scanServices()}
        aria-label="Scan for services"
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
          stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <circle cx="11" cy="11" r="8"/>
          <line x1="21" y1="21" x2="16.65" y2="16.65"/>
        </svg>
        Scan
      </button>
      <button
        class="cp-btn cp-btn--primary"
        onclick={() => { showAddModal = true; }}
        aria-label="Add connector"
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
          stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <line x1="12" y1="5" x2="12" y2="19"/>
          <line x1="5" y1="12" x2="19" y2="12"/>
        </svg>
        Add
      </button>
    </div>
  </header>

  <!-- Detected services (shows itself when scanning or services found) -->
  <ServiceScanner
    bind:this={scanner}
    {addedUrls}
    onAdd={handleAddFromDetected}
  />

  <!-- Manual connectors list -->
  <section class="cp-section">
    <h2 class="cp-section-title">Connected</h2>

    {#if connectors.length === 0}
      <div class="cp-empty">
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor"
          stroke-width="1" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M13.19 8.688a4.5 4.5 0 011.242 7.244l-4.5 4.5a4.5 4.5 0 01-6.364-6.364l1.757-1.757m9.86-2.556a4.5 4.5 0 00-6.364-6.364L4.5 8.25l4.5 4.5 4.19-4.062z"/>
        </svg>
        <p>No connectors yet. Scan for services or add one manually.</p>
      </div>
    {:else}
      <div class="cp-list">
        {#each connectors as connector (connector.id)}
          <ConnectorCard
            {connector}
            onConnect={handleConnect}
            onRemove={handleRemove}
          />
        {/each}
      </div>
    {/if}
  </section>
</div>

<!-- Add connector modal -->
{#if showAddModal}
  <ConnectorForm
    onSubmit={handleFormSubmit}
    onCancel={() => { showAddModal = false; }}
  />
{/if}

<style>
  .cp-page {
    height: 100%;
    overflow-y: auto;
    padding: 32px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .cp-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    margin-bottom: 28px;
  }

  .cp-title {
    font-size: 1.5rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.02em;
  }

  .cp-subtitle {
    font-size: 0.875rem;
    color: var(--text-tertiary);
    margin-top: 4px;
  }

  .cp-header-actions {
    display: flex;
    gap: 8px;
  }

  .cp-section {
    margin-bottom: 28px;
  }

  .cp-section-title {
    font-size: 0.8125rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-tertiary);
    margin-bottom: 10px;
  }

  .cp-list {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .cp-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
    padding: 40px;
    color: var(--text-muted);
    text-align: center;
    font-size: 0.875rem;
  }

  .cp-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    border-radius: 9999px;
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.12s, border-color 0.12s;
  }

  .cp-btn--primary {
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.15);
    color: var(--text-primary);
  }

  .cp-btn--primary:hover {
    background: rgba(255, 255, 255, 0.15);
    border-color: rgba(255, 255, 255, 0.25);
  }

  .cp-btn--ghost {
    background: transparent;
    border: 1px solid var(--border-default);
    color: var(--text-secondary);
  }

  .cp-btn--ghost:hover {
    background: rgba(255, 255, 255, 0.05);
    border-color: var(--border-hover);
  }
</style>
