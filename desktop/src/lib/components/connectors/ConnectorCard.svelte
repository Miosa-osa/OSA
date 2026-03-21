<script lang="ts">
  import { fly } from 'svelte/transition';
  import type { ConnectorType, ConnectorStatus, Connector } from './types';

  // ── Props ───────────────────────────────────────────────────────────────────

  interface Props {
    connector: Connector;
    onConnect: (connector: Connector) => void;
    onRemove: (id: string) => void;
  }

  let { connector, onConnect, onRemove }: Props = $props();

  // ── Helpers ──────────────────────────────────────────────────────────────────

  const STATUS_COLOR: Record<ConnectorStatus, string> = {
    connected:    'rgba(34, 197, 94, 0.8)',
    disconnected: 'rgba(255, 255, 255, 0.25)',
    error:        'rgba(239, 68, 68, 0.8)',
  };

  function typeIcon(type: ConnectorType): string {
    switch (type) {
      case 'repo':   return 'M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253';
      case 'server': return 'M5.25 14.5h13.5m-13.5 0a3 3 0 01-3-3m3 3a3 3 0 100 6h13.5a3 3 0 100-6m-16.5-3a3 3 0 013-3h13.5a3 3 0 013 3m-19.5 0a4.5 4.5 0 01.9-2.7L5.737 5.1a3.375 3.375 0 012.7-1.35h7.126c1.062 0 2.062.5 2.7 1.35l2.587 3.45a4.5 4.5 0 01.9 2.7m0 0h.375a2.625 2.625 0 010 5.25H17.25';
      case 'app':    return 'M9 17.25v1.007a3 3 0 01-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0115 18.257V17.25m6-12V15a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 15V5.25m18 0A2.25 2.25 0 0018.75 3H5.25A2.25 2.25 0 003 5.25m18 0V12a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 12V5.25';
      case 'custom': return 'M11.42 15.17l-5.1-5.1m0 0L11.42 5m-5.1 5.07h13.56';
    }
  }

  const TYPE_LABEL: Record<ConnectorType, string> = {
    repo:   'Repo',
    server: 'Server',
    app:    'App',
    custom: 'Custom',
  };
</script>

<div class="cc-row" transition:fly={{ y: 8, duration: 150 }}>
  <!-- Status dot -->
  <span
    class="cc-status-dot"
    style:background={STATUS_COLOR[connector.status]}
    aria-label="Status: {connector.status}"
  ></span>

  <!-- Type icon -->
  <svg class="cc-type-icon" width="16" height="16" viewBox="0 0 24 24" fill="none"
    stroke="currentColor" stroke-width="1.5" stroke-linecap="round"
    stroke-linejoin="round" aria-hidden="true">
    <path d={typeIcon(connector.type)} />
  </svg>

  <!-- Info -->
  <div class="cc-info">
    <div class="cc-name-row">
      <span class="cc-name">{connector.name}</span>
      <span class="cc-type-badge">{TYPE_LABEL[connector.type]}</span>
    </div>
    <div class="cc-url">{connector.url}</div>
    {#if connector.description}
      <div class="cc-desc">{connector.description}</div>
    {/if}
  </div>

  <!-- Actions -->
  <div class="cc-actions">
    <button
      class="cc-btn cc-btn--ghost"
      onclick={() => onConnect(connector)}
      title="Have OSA connect and analyze this service"
      aria-label="Connect OSA to {connector.name}"
    >
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
        stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/>
      </svg>
      Connect
    </button>
    <button
      class="cc-btn cc-btn--ghost cc-btn--danger"
      onclick={() => onRemove(connector.id)}
      aria-label="Remove {connector.name}"
    >
      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor"
        stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <line x1="18" y1="6" x2="6" y2="18"/>
        <line x1="6" y1="6" x2="18" y2="18"/>
      </svg>
    </button>
  </div>
</div>

<style>
  .cc-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 14px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid var(--border-default);
    border-radius: 10px;
    transition: background 0.12s;
  }

  .cc-row:hover {
    background: rgba(255, 255, 255, 0.05);
  }

  .cc-status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .cc-type-icon {
    color: var(--text-tertiary);
    flex-shrink: 0;
  }

  .cc-info {
    flex: 1;
    min-width: 0;
  }

  .cc-name-row {
    display: flex;
    align-items: center;
    gap: 7px;
  }

  .cc-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary);
  }

  .cc-type-badge {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-muted);
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 4px;
    padding: 1px 5px;
  }

  .cc-url {
    font-size: 0.75rem;
    font-family: var(--font-mono);
    color: var(--text-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    margin-top: 1px;
  }

  .cc-desc {
    font-size: 0.6875rem;
    color: var(--text-muted);
    margin-top: 2px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .cc-actions {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
  }

  .cc-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: 9999px;
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.12s, border-color 0.12s, color 0.12s;
  }

  .cc-btn--ghost {
    background: transparent;
    border: 1px solid var(--border-default);
    color: var(--text-secondary);
  }

  .cc-btn--ghost:hover {
    background: rgba(255, 255, 255, 0.05);
    border-color: var(--border-hover);
  }

  .cc-btn--danger:hover {
    color: rgba(239, 68, 68, 0.8);
    border-color: rgba(239, 68, 68, 0.3);
  }
</style>
