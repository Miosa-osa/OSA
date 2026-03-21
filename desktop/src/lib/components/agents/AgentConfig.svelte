<!-- src/lib/components/agents/AgentConfig.svelte -->
<!-- Configuration tab: agent identity fields derived from name/id/status data. -->
<script lang="ts">
  import type { Agent } from '$lib/api/types';

  interface Props {
    agent: Agent;
  }

  let { agent }: Props = $props();

  let systemPromptExpanded = $state(false);

  // Infer tier from agent name — matches the OSA agent naming convention
  function inferTier(name: string): string {
    const lower = name.toLowerCase();
    if (lower.includes('opus') || lower.includes('orchestrat') || lower.includes('master')) return 'opus';
    if (lower.includes('haiku') || lower.includes('util') || lower.includes('task')) return 'haiku';
    return 'sonnet';
  }

  const tier = $derived(inferTier(agent.name));

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleString(undefined, {
      dateStyle: 'medium',
      timeStyle: 'short',
    });
  }
</script>

<div class="acfg-root">

  <!-- ── Identity ── -->
  <section class="acfg-card" aria-label="Agent identity">
    <h2 class="acfg-section-title">Identity</h2>
    <div class="acfg-field-grid">
      <div class="acfg-field">
        <span class="acfg-field-label">Name</span>
        <span class="acfg-field-value">{agent.name}</span>
      </div>
      <div class="acfg-field">
        <span class="acfg-field-label">Agent ID</span>
        <code class="acfg-code-value" title={agent.id}>{agent.id}</code>
      </div>
      <div class="acfg-field">
        <span class="acfg-field-label">Inferred Tier</span>
        <span
          class="acfg-tier-badge"
          class:acfg-tier-badge--opus={tier === 'opus'}
          class:acfg-tier-badge--sonnet={tier === 'sonnet'}
          class:acfg-tier-badge--haiku={tier === 'haiku'}
        >
          {tier}
        </span>
      </div>
      <div class="acfg-field">
        <span class="acfg-field-label">Status</span>
        <span class="acfg-field-value" style="text-transform: capitalize">{agent.status}</span>
      </div>
    </div>
  </section>

  <!-- ── Lifecycle ── -->
  <section class="acfg-card" aria-label="Agent lifecycle">
    <h2 class="acfg-section-title">Lifecycle</h2>
    <div class="acfg-field-grid">
      <div class="acfg-field">
        <span class="acfg-field-label">Created At</span>
        <span class="acfg-field-value">{formatDate(agent.created_at)}</span>
      </div>
      <div class="acfg-field">
        <span class="acfg-field-label">Last Updated</span>
        <span class="acfg-field-value">{formatDate(agent.updated_at)}</span>
      </div>
      <div class="acfg-field">
        <span class="acfg-field-label">Progress</span>
        <div class="acfg-progress-row">
          <div class="acfg-progress-track" role="progressbar" aria-valuenow={agent.progress} aria-valuemin={0} aria-valuemax={100} aria-label="Progress">
            <div class="acfg-progress-fill" style="width: {agent.progress}%"></div>
          </div>
          <span class="acfg-field-value">{agent.progress}%</span>
        </div>
      </div>
    </div>
  </section>

  <!-- ── Current task ── -->
  {#if agent.task}
    <section class="acfg-card" aria-label="Current task">
      <h2 class="acfg-section-title">Current Task</h2>
      <p class="acfg-task-text">{agent.task}</p>
    </section>
  {/if}

  <!-- ── System prompt (placeholder) ── -->
  <section class="acfg-card" aria-label="System prompt">
    <div class="acfg-collapsible-header">
      <h2 class="acfg-section-title" style="margin-bottom: 0">System Prompt</h2>
      <button
        class="acfg-toggle-btn"
        onclick={() => (systemPromptExpanded = !systemPromptExpanded)}
        aria-expanded={systemPromptExpanded}
        aria-label="{systemPromptExpanded ? 'Collapse' : 'Expand'} system prompt"
      >
        <svg
          width="12"
          height="12"
          viewBox="0 0 12 12"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          aria-hidden="true"
          style="transition: transform 0.18s ease; transform: rotate({systemPromptExpanded ? 90 : 0}deg)"
        >
          <polyline points="4,2 8,6 4,10"/>
        </svg>
        {systemPromptExpanded ? 'Collapse' : 'Expand'}
      </button>
    </div>

    {#if systemPromptExpanded}
      <div class="acfg-prompt-box" role="region" aria-label="System prompt content">
        <p class="acfg-prompt-hint">
          System prompt details are loaded from the OSA agent CLAUDE.md files and injected at runtime.
          The agent name <strong>{agent.name}</strong> maps to its corresponding agent definition.
        </p>
        <div class="acfg-prompt-meta">
          <span class="acfg-meta-tag">Agent: {agent.name}</span>
          <span class="acfg-meta-tag">Tier: {tier}</span>
        </div>
      </div>
    {/if}
  </section>

  <!-- ── Raw data ── -->
  <section class="acfg-card" aria-label="Raw agent data">
    <h2 class="acfg-section-title">Raw Data</h2>
    <pre class="acfg-raw-json">{JSON.stringify(agent, null, 2)}</pre>
  </section>

</div>

<style>
  .acfg-root {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .acfg-card {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
    padding: 16px 18px;
  }

  .acfg-section-title {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--text-muted);
    margin-bottom: 12px;
  }

  /* ── Field grid ── */

  .acfg-field-grid {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .acfg-field {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 16px;
    padding: 8px 10px;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.04);
    border-radius: var(--radius-md);
  }

  .acfg-field-label {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-muted);
    white-space: nowrap;
    flex-shrink: 0;
    padding-top: 1px;
  }

  .acfg-field-value {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    text-align: right;
    word-break: break-all;
  }

  .acfg-code-value {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.03);
    padding: 2px 6px;
    border-radius: var(--radius-xs);
    border: 1px solid rgba(255, 255, 255, 0.05);
    word-break: break-all;
    user-select: text;
    text-align: right;
  }

  /* ── Tier badge ── */

  .acfg-tier-badge {
    display: inline-flex;
    padding: 1px 8px;
    border-radius: var(--radius-full);
    font-size: 0.625rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    background: rgba(255, 255, 255, 0.07);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  .acfg-tier-badge--opus {
    background: rgba(168, 85, 247, 0.12);
    color: rgba(168, 85, 247, 0.9);
    border-color: rgba(168, 85, 247, 0.25);
  }

  .acfg-tier-badge--sonnet {
    background: rgba(59, 130, 246, 0.1);
    color: rgba(59, 130, 246, 0.9);
    border-color: rgba(59, 130, 246, 0.2);
  }

  .acfg-tier-badge--haiku {
    background: rgba(34, 197, 94, 0.09);
    color: rgba(34, 197, 94, 0.85);
    border-color: rgba(34, 197, 94, 0.18);
  }

  /* ── Progress row ── */

  .acfg-progress-row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    justify-content: flex-end;
  }

  .acfg-progress-track {
    width: 80px;
    height: 3px;
    background: rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    overflow: hidden;
    flex-shrink: 0;
  }

  .acfg-progress-fill {
    height: 100%;
    background: linear-gradient(90deg, rgba(59, 130, 246, 0.6), rgba(59, 130, 246, 0.9));
    border-radius: var(--radius-full);
  }

  /* ── Task ── */

  .acfg-task-text {
    font-size: 0.875rem;
    color: var(--text-secondary);
    line-height: 1.6;
  }

  /* ── Collapsible header ── */

  .acfg-collapsible-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-bottom: 0;
  }

  .acfg-toggle-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-full);
    color: var(--text-tertiary);
    font-size: 0.6875rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }

  .acfg-toggle-btn:hover {
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-secondary);
  }

  /* ── Prompt box ── */

  .acfg-prompt-box {
    margin-top: 12px;
    padding: 12px 14px;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-md);
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .acfg-prompt-hint {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    line-height: 1.6;
  }

  .acfg-prompt-hint strong {
    color: var(--text-secondary);
    font-weight: 600;
  }

  .acfg-prompt-meta {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }

  .acfg-meta-tag {
    padding: 2px 8px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-full);
    font-size: 0.6875rem;
    color: var(--text-tertiary);
  }

  /* ── Raw JSON ── */

  .acfg-raw-json {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.04);
    border-radius: var(--radius-md);
    padding: 12px 14px;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 240px;
    overflow-y: auto;
    margin: 0;
    line-height: 1.6;
    user-select: text;
  }
</style>
