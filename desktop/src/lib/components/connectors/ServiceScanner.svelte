<script lang="ts">
  import { fly } from 'svelte/transition';
  import type { ConnectorType, DetectedService } from './types';

  // ── Props ───────────────────────────────────────────────────────────────────

  interface Props {
    addedUrls: string[];
    onAdd: (service: DetectedService) => void;
  }

  let { addedUrls, onAdd }: Props = $props();

  // ── State ───────────────────────────────────────────────────────────────────

  let detectedServices = $state<DetectedService[]>([]);
  let scanning = $state(false);

  // ── Constants ────────────────────────────────────────────────────────────────

  const KNOWN_PORTS: { port: number; name: string; type: ConnectorType }[] = [
    { port: 3000,  name: 'Dev Server (3000)',    type: 'server' },
    { port: 3001,  name: 'Dev Server (3001)',    type: 'server' },
    { port: 4000,  name: 'Phoenix (4000)',        type: 'server' },
    { port: 5173,  name: 'Vite (5173)',           type: 'server' },
    { port: 5199,  name: 'OSA Frontend (5199)',   type: 'app'    },
    { port: 8000,  name: 'Python Server (8000)',  type: 'server' },
    { port: 8080,  name: 'HTTP Server (8080)',    type: 'server' },
    { port: 8888,  name: 'Jupyter (8888)',        type: 'app'    },
    { port: 9089,  name: 'OSA Backend (9089)',    type: 'app'    },
    { port: 11434, name: 'Ollama (11434)',         type: 'app'    },
    { port: 5432,  name: 'PostgreSQL (5432)',      type: 'server' },
    { port: 6379,  name: 'Redis (6379)',           type: 'server' },
    { port: 27017, name: 'MongoDB (27017)',        type: 'server' },
  ];

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function typeIcon(type: ConnectorType): string {
    switch (type) {
      case 'repo':   return 'M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253';
      case 'server': return 'M5.25 14.5h13.5m-13.5 0a3 3 0 01-3-3m3 3a3 3 0 100 6h13.5a3 3 0 100-6m-16.5-3a3 3 0 013-3h13.5a3 3 0 013 3m-19.5 0a4.5 4.5 0 01.9-2.7L5.737 5.1a3.375 3.375 0 012.7-1.35h7.126c1.062 0 2.062.5 2.7 1.35l2.587 3.45a4.5 4.5 0 01.9 2.7m0 0h.375a2.625 2.625 0 010 5.25H17.25';
      case 'app':    return 'M9 17.25v1.007a3 3 0 01-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0115 18.257V17.25m6-12V15a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 15V5.25m18 0A2.25 2.25 0 0018.75 3H5.25A2.25 2.25 0 003 5.25m18 0V12a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 12V5.25';
      case 'custom': return 'M11.42 15.17l-5.1-5.1m0 0L11.42 5m-5.1 5.07h13.56';
    }
  }

  // ── Scan ─────────────────────────────────────────────────────────────────────

  export async function scanServices() {
    scanning = true;
    detectedServices = [];

    const results: DetectedService[] = [];

    const checks = KNOWN_PORTS.map(async ({ port, name, type }) => {
      try {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 1500);
        await fetch(`http://127.0.0.1:${port}`, {
          mode: 'no-cors',
          signal: controller.signal,
        });
        clearTimeout(timeout);
        results.push({ name, port, type, url: `http://127.0.0.1:${port}` });
      } catch {
        // Port not responding — skip
      }
    });

    await Promise.allSettled(checks);
    detectedServices = results.sort((a, b) => a.port - b.port);
    scanning = false;
  }
</script>

{#if scanning || detectedServices.length > 0}
  <section class="ss-section" transition:fly={{ y: 12, duration: 200 }}>
    <h2 class="ss-title">Detected Services</h2>
    <p class="ss-desc">
      {#if scanning}
        Scanning local ports…
      {:else}
        Services running on your machine right now.
      {/if}
    </p>

    {#if scanning}
      <div class="ss-scanning" role="status" aria-label="Scanning for services">
        <span class="ss-spinner" aria-hidden="true"></span>
        <span class="ss-scanning-text">Scanning {KNOWN_PORTS.length} ports…</span>
      </div>
    {:else if detectedServices.length > 0}
      <div class="ss-grid">
        {#each detectedServices as service (service.port)}
          {@const alreadyAdded = addedUrls.includes(service.url)}
          <div class="ss-card">
            <div class="ss-info">
              <svg class="ss-icon" width="16" height="16" viewBox="0 0 24 24" fill="none"
                stroke="currentColor" stroke-width="1.5" stroke-linecap="round"
                stroke-linejoin="round" aria-hidden="true">
                <path d={typeIcon(service.type)} />
              </svg>
              <div>
                <div class="ss-name">{service.name}</div>
                <div class="ss-url">{service.url}</div>
              </div>
            </div>
            <button
              class="ss-btn"
              class:ss-btn--added={alreadyAdded}
              onclick={() => onAdd(service)}
              disabled={alreadyAdded}
              aria-label={alreadyAdded ? `${service.name} already added` : `Add ${service.name}`}
            >
              {alreadyAdded ? 'Added' : 'Add'}
            </button>
          </div>
        {/each}
      </div>
    {/if}
  </section>
{/if}

<style>
  .ss-section {
    margin-bottom: 28px;
  }

  .ss-title {
    font-size: 0.8125rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-tertiary);
    margin-bottom: 6px;
  }

  .ss-desc {
    font-size: 0.8125rem;
    color: var(--text-muted);
    margin-bottom: 14px;
  }

  .ss-scanning {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 14px 0;
  }

  .ss-scanning-text {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
  }

  .ss-spinner {
    width: 14px;
    height: 14px;
    border: 2px solid rgba(255, 255, 255, 0.15);
    border-top-color: rgba(255, 255, 255, 0.6);
    border-radius: 50%;
    animation: ss-spin 0.6s linear infinite;
    flex-shrink: 0;
  }

  @keyframes ss-spin {
    to { transform: rotate(360deg); }
  }

  .ss-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
    gap: 8px;
  }

  .ss-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid var(--border-default);
    border-radius: 10px;
    transition: background 0.12s;
  }

  .ss-card:hover {
    background: rgba(255, 255, 255, 0.06);
  }

  .ss-info {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .ss-icon {
    color: var(--text-tertiary);
    flex-shrink: 0;
  }

  .ss-name {
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-primary);
  }

  .ss-url {
    font-size: 0.6875rem;
    font-family: var(--font-mono);
    color: var(--text-muted);
  }

  .ss-btn {
    padding: 4px 10px;
    font-size: 0.75rem;
    border-radius: 9999px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid var(--border-default);
    color: var(--text-secondary);
    cursor: pointer;
    transition: background 0.12s;
    flex-shrink: 0;
  }

  .ss-btn:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.12);
  }

  .ss-btn--added {
    color: rgba(34, 197, 94, 0.7);
    border-color: rgba(34, 197, 94, 0.2);
  }

  .ss-btn:disabled {
    cursor: default;
  }
</style>
