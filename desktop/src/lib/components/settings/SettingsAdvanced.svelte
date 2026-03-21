<script lang="ts">
  import { health } from '$lib/api/client';
  import { restartBackend as restartBackendUtil } from '$lib/utils/backend';

  interface Props {
    contextWindow: number | null;
  }

  let { contextWindow }: Props = $props();

  let backendUrl        = $state('http://127.0.0.1:9089');
  let logLevel          = $state<'error' | 'warn' | 'info' | 'debug'>('info');
  let doctorOutput      = $state('');
  let runningDoctor     = $state(false);
  let restartingBackend = $state(false);

  async function restartBackend() {
    restartingBackend = true;
    try {
      await restartBackendUtil();
    } catch {
      // command may not exist in dev — ignore
    } finally {
      restartingBackend = false;
    }
  }

  async function runDoctor() {
    runningDoctor = true;
    doctorOutput  = '';
    try {
      const h = await health.get();
      const uptimeLine = h.uptime_seconds != null
        ? `Uptime:   ${Math.floor(h.uptime_seconds / 60)}m ${h.uptime_seconds % 60}s`
        : null;
      const agentsLine = h.agents_active != null
        ? `Agents active: ${h.agents_active}`
        : null;
      doctorOutput = [
        `Status:   ${h.status}`,
        `Version:  ${h.version}`,
        `Provider: ${h.provider ?? 'none'}`,
        `Model:    ${h.model ?? 'none'}`,
        `Context:  ${h.context_window != null ? h.context_window.toLocaleString() + ' tokens' : '—'}`,
        agentsLine,
        uptimeLine,
      ].filter(Boolean).join('\n');
    } catch (err) {
      doctorOutput = `Backend unreachable.\n${err instanceof Error ? err.message : String(err)}`;
    } finally {
      runningDoctor = false;
    }
  }
</script>

<section class="sa-section">
  <h2 class="sa-section-title">Advanced</h2>
  <p class="sa-section-desc">Backend connection, logging, and diagnostics.</p>

  <div class="sa-settings-group">
    <!-- Backend URL -->
    <div class="sa-settings-item">
      <div class="sa-item-meta">
        <span class="sa-item-label">Backend URL</span>
        <span class="sa-item-hint">OSA backend address.</span>
      </div>
      <input
        type="url"
        class="sa-field-input"
        bind:value={backendUrl}
        placeholder="http://127.0.0.1:9089"
        spellcheck={false}
        aria-label="Backend URL"
      />
    </div>

    <div class="sa-item-divider"></div>

    <!-- Context window (read-only) -->
    <div class="sa-settings-item">
      <div class="sa-item-meta">
        <span class="sa-item-label">Context window</span>
        <span class="sa-item-hint">Active model's max token limit.</span>
      </div>
      <span class="sa-field-readonly">
        {contextWindow !== null ? contextWindow.toLocaleString() + ' tokens' : '—'}
      </span>
    </div>

    <div class="sa-item-divider"></div>

    <!-- Log level -->
    <div class="sa-settings-item">
      <div class="sa-item-meta">
        <span class="sa-item-label">Log level</span>
        <span class="sa-item-hint">Verbosity for backend logs.</span>
      </div>
      <select class="sa-field-select" bind:value={logLevel} aria-label="Log level">
        <option value="error">Error</option>
        <option value="warn">Warn</option>
        <option value="info">Info</option>
        <option value="debug">Debug</option>
      </select>
    </div>
  </div>

  <!-- Action buttons -->
  <div class="sa-action-row">
    <button
      type="button"
      class="sa-btn-ghost"
      onclick={restartBackend}
      disabled={restartingBackend}
      aria-label="Restart the backend process"
    >
      {#if restartingBackend}
        <span class="sa-spinner sa-spinner--dark" aria-hidden="true"></span>
        Restarting…
      {:else}
        <svg width="13" height="13" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/></svg>
        Restart backend
      {/if}
    </button>

    <button
      type="button"
      class="sa-btn-ghost"
      onclick={runDoctor}
      disabled={runningDoctor}
      aria-label="Run backend health check"
    >
      {#if runningDoctor}
        <span class="sa-spinner sa-spinner--dark" aria-hidden="true"></span>
        Running…
      {:else}
        <svg width="13" height="13" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
        Run doctor
      {/if}
    </button>
  </div>

  {#if doctorOutput}
    <div class="sa-doctor-output" role="region" aria-label="Doctor output" aria-live="polite">
      <pre class="sa-doctor-pre">{doctorOutput}</pre>
    </div>
  {/if}
</section>

<style>
  .sa-section { max-width: 560px; }

  .sa-section-title {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
    margin: 0 0 4px;
  }

  .sa-section-desc {
    font-size: 13px;
    color: var(--text-tertiary);
    margin: 0 0 24px;
  }

  .sa-settings-group {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 12px;
    overflow: hidden;
  }

  .sa-settings-item { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 13px 16px; min-height: 52px; }
  .sa-item-divider { height: 1px; background: rgba(255,255,255,0.06); }
  .sa-item-meta { display: flex; flex-direction: column; gap: 2px; flex-shrink: 0; }
  .sa-item-label { font-size: 14px; color: rgba(255,255,255,0.88); font-weight: 450; white-space: nowrap; }
  .sa-item-hint { font-size: 11.5px; color: var(--text-tertiary); }

  .sa-field-input {
    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.09); border-radius: 8px;
    padding: 7px 12px; color: rgba(255,255,255,0.9); font-size: 13px; outline: none;
    transition: border-color 0.15s ease, background 0.15s ease; width: 220px; min-width: 0;
  }
  .sa-field-input::placeholder { color: rgba(255,255,255,0.2); }
  .sa-field-input:focus { border-color: rgba(255,255,255,0.22); background: rgba(255,255,255,0.07); }

  .sa-field-select {
    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.09); border-radius: 8px;
    padding: 7px 28px 7px 12px; color: rgba(255,255,255,0.9); font-size: 13px; outline: none; cursor: pointer;
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 24 24' fill='none' stroke='%23666' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M6 9l6 6 6-6'/%3E%3C/svg%3E");
    background-repeat: no-repeat; background-position: right 10px center; transition: border-color 0.15s ease;
  }
  .sa-field-select:focus { border-color: rgba(255,255,255,0.22); }
  .sa-field-readonly { font-size: 13px; color: var(--text-tertiary); font-variant-numeric: tabular-nums; display: flex; align-items: center; gap: 6px; }

  .sa-btn-ghost {
    display: inline-flex; align-items: center; gap: 6px; padding: 7px 14px;
    background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 9999px;
    color: rgba(255,255,255,0.6); font-size: 13px; font-weight: 450; cursor: pointer;
    transition: background 0.13s ease, color 0.13s ease, border-color 0.13s ease;
  }
  .sa-btn-ghost:hover:not(:disabled) { background: rgba(255,255,255,0.07); color: rgba(255,255,255,0.85); border-color: rgba(255,255,255,0.13); }
  .sa-btn-ghost:disabled { opacity: 0.45; cursor: not-allowed; }
  .sa-btn-ghost:focus-visible { outline: 2px solid rgba(255,255,255,0.3); outline-offset: 2px; }

  .sa-action-row { margin-top: 20px; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .sa-doctor-output { margin-top: 16px; background: rgba(0,0,0,0.35); border: 1px solid rgba(255,255,255,0.06); border-radius: 10px; padding: 14px 16px; }
  .sa-doctor-pre { font-family: var(--font-mono); font-size: 12px; color: rgba(255,255,255,0.65); white-space: pre-wrap; word-break: break-all; margin: 0; line-height: 1.7; }

  .sa-spinner { display: inline-block; width: 13px; height: 13px; border: 2px solid rgba(255,255,255,0.2); border-top-color: rgba(255,255,255,0.8); border-radius: 9999px; animation: sa-spin 0.6s linear infinite; flex-shrink: 0; }
  .sa-spinner--dark { border-color: rgba(255,255,255,0.12); border-top-color: rgba(255,255,255,0.5); }
  @keyframes sa-spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) { .sa-spinner { animation: none; opacity: 0.5; } }
</style>
