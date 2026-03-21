<script lang="ts">
  import { fly } from 'svelte/transition';
  import { BASE_URL, API_PREFIX, getToken } from '$lib/api/client';

  // ── Types ────────────────────────────────────────────────────────────────────

  type StepType = 'tool_call' | 'thinking' | 'message' | 'error' | 'system';

  interface TokenUsage {
    input: number;
    output: number;
    cost_cents: number;
  }

  interface TranscriptStep {
    id: string;
    type: StepType;
    timestamp: string;
    duration_ms?: number;
    // tool_call
    tool_name?: string;
    tool_args?: Record<string, unknown>;
    tool_result?: string;
    is_error?: boolean;
    // thinking
    thinking?: string;
    // message
    role?: 'user' | 'assistant' | 'tool';
    content?: string;
    // error
    error_message?: string;
    // cost
    token_usage?: TokenUsage;
  }

  interface RunSummary {
    run_id: string;
    agent_id?: string;
    status: string;
    started_at: string;
    completed_at?: string;
    total_duration_ms?: number;
    total_tokens?: number;
    total_cost_cents?: number;
    step_count?: number;
    steps: TranscriptStep[];
  }

  interface RunTranscriptProps {
    runId: string;
    agentId?: string;
    onClose?: () => void;
    compact?: boolean;
  }

  // ── Props ────────────────────────────────────────────────────────────────────

  let { runId, agentId, onClose, compact = false }: RunTranscriptProps = $props();

  // ── State ────────────────────────────────────────────────────────────────────

  let loading = $state(true);
  let error = $state<string | null>(null);
  let transcript = $state<RunSummary | null>(null);
  let expandedSteps = $state<Set<string>>(new Set());
  let searchQuery = $state('');
  let searchVisible = $state(false);
  let viewportEl = $state<HTMLDivElement | null>(null);
  let isAtBottom = $state(true);
  let searchInputEl = $state<HTMLInputElement | null>(null);

  // ── Derived ──────────────────────────────────────────────────────────────────

  const steps = $derived(transcript?.steps ?? []);

  const filteredSteps = $derived(() => {
    if (!searchQuery.trim()) return steps;
    const q = searchQuery.toLowerCase();
    return steps.filter((s) => {
      return (
        s.tool_name?.toLowerCase().includes(q) ||
        s.content?.toLowerCase().includes(q) ||
        s.thinking?.toLowerCase().includes(q) ||
        s.tool_result?.toLowerCase().includes(q) ||
        s.error_message?.toLowerCase().includes(q) ||
        JSON.stringify(s.tool_args ?? {}).toLowerCase().includes(q)
      );
    });
  });

  const totalDurationMs = $derived(
    transcript?.total_duration_ms ??
      (transcript?.completed_at && transcript?.started_at
        ? new Date(transcript.completed_at).getTime() - new Date(transcript.started_at).getTime()
        : null)
  );


  const totalTokens = $derived(
    transcript?.total_tokens ??
      steps.reduce((acc, s) => acc + (s.token_usage?.input ?? 0) + (s.token_usage?.output ?? 0), 0)
  );

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function formatDuration(ms: number | null | undefined): string {
    if (ms == null) return '—';
    if (ms < 1000) return `${ms}ms`;
    if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
    const m = Math.floor(ms / 60_000);
    const s = Math.floor((ms % 60_000) / 1000);
    return `${m}m ${s}s`;
  }

  function formatCost(cents: number | null | undefined): string {
    if (cents == null) return '—';
    if (cents === 0) return '$0.00';
    const usd = cents / 100;
    return usd < 0.01 ? '<$0.01' : `$${usd.toFixed(4)}`;
  }

  function formatTokens(n: number): string {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
    return String(n);
  }

  function formatTime(iso: string): string {
    try {
      return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    } catch {
      return iso;
    }
  }

  function summariseArgs(args: Record<string, unknown> | undefined): string {
    if (!args) return '';
    const entries = Object.entries(args);
    if (!entries.length) return '';
    const [key, val] = entries[0];
    const valStr = typeof val === 'string' ? val : JSON.stringify(val);
    const preview = valStr.length > 60 ? valStr.slice(0, 60) + '…' : valStr;
    return entries.length === 1 ? `${key}=${preview}` : `${key}=${preview} +${entries.length - 1}`;
  }

  function summariseResult(result: string | undefined): string {
    if (!result) return '';
    return result.length > 120 ? result.slice(0, 120) + '…' : result;
  }

  function toggleExpand(id: string): void {
    const next = new Set(expandedSteps);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    expandedSteps = next;
  }

  async function copyStep(step: TranscriptStep): Promise<void> {
    const text =
      step.type === 'tool_call'
        ? `${step.tool_name}(${JSON.stringify(step.tool_args ?? {})})\n→ ${step.tool_result ?? ''}`
        : step.type === 'thinking'
          ? step.thinking ?? ''
          : step.content ?? step.error_message ?? '';
    await navigator.clipboard.writeText(text).catch(() => {});
  }

  function toggleSearch(): void {
    searchVisible = !searchVisible;
    if (searchVisible) {
      requestAnimationFrame(() => searchInputEl?.focus());
    } else {
      searchQuery = '';
    }
  }

  function handleSearchKey(e: KeyboardEvent): void {
    if (e.key === 'Escape') {
      searchVisible = false;
      searchQuery = '';
    }
  }

  // Keyboard shortcut Ctrl+F / Cmd+F
  function handleGlobalKey(e: KeyboardEvent): void {
    if ((e.ctrlKey || e.metaKey) && e.key === 'f') {
      e.preventDefault();
      toggleSearch();
    }
  }

  // ── Scroll management ────────────────────────────────────────────────────────

  function handleScroll(): void {
    if (!viewportEl) return;
    const { scrollTop, scrollHeight, clientHeight } = viewportEl;
    isAtBottom = scrollHeight - scrollTop - clientHeight < 40;
  }

  function scrollToBottom(): void {
    isAtBottom = true;
    viewportEl?.scrollTo({ top: viewportEl.scrollHeight, behavior: 'smooth' });
  }

  $effect(() => {
    const _steps = steps.length;
    void _steps;
    if (isAtBottom && viewportEl) {
      requestAnimationFrame(() => {
        if (viewportEl) viewportEl.scrollTop = viewportEl.scrollHeight;
      });
    }
  });

  // ── Data fetch ───────────────────────────────────────────────────────────────

  async function fetchTranscript(): Promise<void> {
    loading = true;
    error = null;
    try {
      const token = getToken();
      const headers: Record<string, string> = { Accept: 'application/json' };
      if (token) headers['Authorization'] = `Bearer ${token}`;

      const params = agentId ? `?agent_id=${encodeURIComponent(agentId)}` : '';
      const url = `${BASE_URL}${API_PREFIX}/command-center/runs/${encodeURIComponent(runId)}${params}`;
      const res = await fetch(url, { headers });

      if (!res.ok) {
        const body = await res.text().catch(() => '');
        throw new Error(`HTTP ${res.status}: ${body || 'Failed to load transcript'}`);
      }

      const data = (await res.json()) as RunSummary;
      transcript = data;
    } catch (err) {
      error = err instanceof Error ? err.message : 'Failed to load run transcript';
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    void runId;
    void fetchTranscript();
  });
</script>

<svelte:window onkeydown={handleGlobalKey} />

<div
  class="rt-root"
  class:rt-root--compact={compact}
  aria-label="Run transcript viewer"
>

  <!-- ── Header ── -->
  <header class="rt-header">
    <div class="rt-header-left">
      <h2 class="rt-title">Run Transcript</h2>
      {#if runId}
        <span class="rt-run-id" title={runId}>{runId.slice(0, 8)}</span>
      {/if}
    </div>
    <div class="rt-header-actions">
      <!-- Search toggle -->
      <button
        class="rt-icon-btn"
        class:rt-icon-btn--active={searchVisible}
        onclick={toggleSearch}
        aria-label="Search transcript (Ctrl+F)"
        title="Search (Ctrl+F)"
      >
        <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <circle cx="5.5" cy="5.5" r="3.5"/>
          <line x1="8.5" y1="8.5" x2="11" y2="11"/>
        </svg>
      </button>
      <!-- Refresh -->
      <button
        class="rt-icon-btn"
        onclick={fetchTranscript}
        disabled={loading}
        aria-label="Refresh transcript"
        title="Refresh"
      >
        <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" class:rt-spin={loading}>
          <path d="M11 6.5A4.5 4.5 0 002 6.5"/>
          <path d="M11 4.5v2H9"/>
        </svg>
      </button>
      <!-- Close -->
      {#if onClose}
        <button class="rt-icon-btn" onclick={onClose} aria-label="Close transcript">
          <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
            <line x1="2" y1="2" x2="11" y2="11"/>
            <line x1="11" y1="2" x2="2" y2="11"/>
          </svg>
        </button>
      {/if}
    </div>
  </header>

  <!-- ── Search bar ── -->
  {#if searchVisible}
    <div class="rt-search-bar" transition:fly={{ y: -6, duration: 160 }}>
      <svg width="12" height="12" viewBox="0 0 13 13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <circle cx="5.5" cy="5.5" r="3.5"/>
        <line x1="8.5" y1="8.5" x2="11" y2="11"/>
      </svg>
      <input
        bind:this={searchInputEl}
        bind:value={searchQuery}
        class="rt-search-input"
        type="text"
        placeholder="Search steps…"
        aria-label="Search transcript steps"
        onkeydown={handleSearchKey}
      />
      {#if searchQuery}
        <span class="rt-search-count">
          {filteredSteps().length} / {steps.length}
        </span>
      {/if}
    </div>
  {/if}

  <!-- ── Summary bar ── -->
  {#if transcript && !loading}
    <div class="rt-summary" role="status" aria-label="Run summary">
      <div class="rt-stat">
        <span class="rt-stat-label">Steps</span>
        <span class="rt-stat-value">{steps.length}</span>
      </div>
      <div class="rt-stat-sep" aria-hidden="true"></div>
      <div class="rt-stat">
        <span class="rt-stat-label">Duration</span>
        <span class="rt-stat-value">{formatDuration(totalDurationMs)}</span>
      </div>
      <div class="rt-stat-sep" aria-hidden="true"></div>
      <div class="rt-stat">
        <span class="rt-stat-label">Tokens</span>
        <span class="rt-stat-value">{formatTokens(totalTokens)}</span>
      </div>
      <div class="rt-stat-sep" aria-hidden="true"></div>
      <div class="rt-stat">
        <span class="rt-stat-label">Cost</span>
        <span class="rt-stat-value">{formatCost(transcript.total_cost_cents)}</span>
      </div>
      <div class="rt-stat-sep" aria-hidden="true"></div>
      <div class="rt-stat">
        <span class="rt-stat-label">Status</span>
        <span class="rt-stat-value rt-status" data-status={transcript.status}>{transcript.status}</span>
      </div>
    </div>
  {/if}

  <!-- ── Viewport ── -->
  <div
    class="rt-viewport"
    bind:this={viewportEl}
    onscroll={handleScroll}
    role="log"
    aria-live="polite"
    aria-relevant="additions"
    aria-label="Execution steps"
  >

    <!-- Loading skeleton -->
    {#if loading}
      <div class="rt-list" aria-label="Loading transcript">
        {#each Array(6) as _, i (i)}
          <div class="rt-skeleton-row">
            <div class="rt-skeleton rt-skeleton--ts"></div>
            <div class="rt-skeleton rt-skeleton--icon"></div>
            <div class="rt-skeleton rt-skeleton--content" style="width: {55 + (i * 7) % 30}%"></div>
            <div class="rt-skeleton rt-skeleton--badge"></div>
          </div>
        {/each}
      </div>

    <!-- Error state -->
    {:else if error}
      <div class="rt-error-state" transition:fly={{ y: 8, duration: 200 }}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <circle cx="12" cy="12" r="10"/>
          <line x1="12" y1="8" x2="12" y2="12"/>
          <line x1="12" y1="16" x2="12.01" y2="16"/>
        </svg>
        <p class="rt-error-msg">{error}</p>
        <button class="rt-retry-btn" onclick={fetchTranscript} aria-label="Retry loading transcript">
          Retry
        </button>
      </div>

    <!-- Empty state -->
    {:else if steps.length === 0}
      <div class="rt-empty-state">
        <p class="rt-empty-msg">No execution steps found for this run.</p>
      </div>

    <!-- Step list -->
    {:else}
      <ol class="rt-list" aria-label="Execution steps">
        {#each filteredSteps() as step (step.id)}
          <li
            class="rt-row rt-row--{step.type}"
            class:rt-row--error={step.is_error}
            transition:fly={{ y: 6, duration: 180 }}
          >
            <!-- Timestamp -->
            <time class="rt-ts" datetime={step.timestamp} title={step.timestamp}>
              {formatTime(step.timestamp)}
            </time>

            <!-- Type icon -->
            <div class="rt-icon-wrap" aria-hidden="true">
              {#if step.type === 'tool_call'}
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M14.7 6.3a1 1 0 000 1.4l1.6 1.6a1 1 0 001.4 0l3.77-3.77a6 6 0 01-7.94 7.94l-6.91 6.91a2.12 2.12 0 01-3-3l6.91-6.91a6 6 0 017.94-7.94l-3.76 3.76z"/>
                </svg>
              {:else if step.type === 'thinking'}
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M9.09 9a3 3 0 015.83 1c0 2-3 3-3 3"/>
                  <circle cx="12" cy="12" r="10"/>
                  <line x1="12" y1="17" x2="12.01" y2="17"/>
                </svg>
              {:else if step.type === 'error'}
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <circle cx="12" cy="12" r="10"/>
                  <line x1="15" y1="9" x2="9" y2="15"/>
                  <line x1="9" y1="9" x2="15" y2="15"/>
                </svg>
              {:else}
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z"/>
                </svg>
              {/if}
            </div>

            <!-- Content -->
            <div class="rt-content">

              {#if step.type === 'tool_call'}
                <div class="rt-tool-header">
                  <span class="rt-tool-name">{step.tool_name ?? 'unknown_tool'}</span>
                  {#if step.tool_args}
                    <code class="rt-args-preview">{summariseArgs(step.tool_args)}</code>
                  {/if}
                  {#if step.is_error}
                    <span class="rt-err-badge" aria-label="Tool error">error</span>
                  {/if}
                </div>
                {#if expandedSteps.has(step.id)}
                  <div class="rt-expanded" transition:fly={{ y: -4, duration: 140 }}>
                    {#if step.tool_args}
                      <pre class="rt-code">args: {JSON.stringify(step.tool_args, null, 2)}</pre>
                    {/if}
                    {#if step.tool_result}
                      <pre class="rt-code rt-code--result">{step.tool_result}</pre>
                    {/if}
                  </div>
                {:else if step.tool_result}
                  <p class="rt-result-preview">{summariseResult(step.tool_result)}</p>
                {/if}

              {:else if step.type === 'thinking'}
                {#if expandedSteps.has(step.id)}
                  <p class="rt-thinking-text" transition:fly={{ y: -4, duration: 140 }}>{step.thinking}</p>
                {:else}
                  <p class="rt-thinking-collapsed">{(step.thinking ?? '').slice(0, 100)}{(step.thinking?.length ?? 0) > 100 ? '…' : ''}</p>
                {/if}

              {:else if step.type === 'message'}
                <div class="rt-msg-header">
                  <span class="rt-msg-role rt-msg-role--{step.role ?? 'assistant'}">{step.role ?? 'assistant'}</span>
                </div>
                <p class="rt-msg-content">{step.content ?? ''}</p>

              {:else if step.type === 'error'}
                <p class="rt-error-text">{step.error_message ?? 'Unknown error'}</p>

              {:else}
                <p class="rt-system-text">{step.content ?? ''}</p>
              {/if}

            </div>

            <!-- Right: cost badge + actions -->
            <div class="rt-row-actions">
              {#if step.token_usage}
                <span class="rt-cost-badge" title="Input: {step.token_usage.input} / Output: {step.token_usage.output} tokens">
                  {formatTokens(step.token_usage.input + step.token_usage.output)}
                  {#if step.token_usage.cost_cents}
                    · {formatCost(step.token_usage.cost_cents)}
                  {/if}
                </span>
              {/if}
              {#if step.duration_ms != null}
                <span class="rt-dur-badge">{formatDuration(step.duration_ms)}</span>
              {/if}
              <!-- Expand toggle for tool_call + thinking -->
              {#if step.type === 'tool_call' || (step.type === 'thinking' && (step.thinking?.length ?? 0) > 100)}
                <button
                  class="rt-expand-btn"
                  onclick={() => toggleExpand(step.id)}
                  aria-expanded={expandedSteps.has(step.id)}
                  aria-label={expandedSteps.has(step.id) ? 'Collapse step' : 'Expand step'}
                >
                  <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true" style="transform: rotate({expandedSteps.has(step.id) ? 180 : 0}deg); transition: transform 0.15s">
                    <polyline points="2,3.5 5,6.5 8,3.5"/>
                  </svg>
                </button>
              {/if}
              <!-- Copy -->
              <button
                class="rt-copy-btn"
                onclick={() => copyStep(step)}
                aria-label="Copy step content"
                title="Copy"
              >
                <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                  <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>
                  <path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/>
                </svg>
              </button>
            </div>
          </li>
        {/each}
      </ol>
    {/if}
  </div>

  <!-- Scroll-to-bottom FAB -->
  {#if !isAtBottom && !loading}
    <button
      class="rt-scroll-fab"
      onclick={scrollToBottom}
      aria-label="Scroll to latest step"
      transition:fly={{ y: 6, duration: 150 }}
    >
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" aria-hidden="true">
        <polyline points="6 9 12 15 18 9"/>
      </svg>
    </button>
  {/if}

</div>

<style>
  /* ── Root ── */

  .rt-root {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: var(--bg-secondary, rgba(10, 10, 15, 0.95));
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-md, 10px);
    overflow: hidden;
    position: relative;
  }

  .rt-root--compact {
    border-radius: var(--radius-sm, 6px);
  }

  /* ── Header ── */

  .rt-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px 10px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
    flex-shrink: 0;
    gap: 8px;
  }

  .rt-header-left {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }

  .rt-title {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary, rgba(255, 255, 255, 0.92));
    letter-spacing: -0.01em;
    margin: 0;
  }

  .rt-run-id {
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.6875rem;
    color: var(--text-muted, rgba(255, 255, 255, 0.3));
    background: rgba(255, 255, 255, 0.05);
    padding: 2px 6px;
    border-radius: var(--radius-sm, 4px);
    flex-shrink: 0;
  }

  .rt-header-actions {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
  }

  .rt-icon-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border-radius: var(--radius-sm, 5px);
    background: transparent;
    border: 1px solid transparent;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.4));
    cursor: pointer;
    transition: background 0.13s, color 0.13s, border-color 0.13s;
  }

  .rt-icon-btn:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.07);
    border-color: rgba(255, 255, 255, 0.1);
    color: var(--text-secondary, rgba(255, 255, 255, 0.7));
  }

  .rt-icon-btn--active {
    background: rgba(99, 102, 241, 0.12);
    border-color: rgba(99, 102, 241, 0.25);
    color: rgba(165, 180, 252, 0.9);
  }

  .rt-icon-btn:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }

  /* ── Search bar ── */

  .rt-search-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 7px 14px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    background: rgba(255, 255, 255, 0.02);
    flex-shrink: 0;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.35));
  }

  .rt-search-input {
    flex: 1;
    background: transparent;
    border: none;
    outline: none;
    font-size: 0.75rem;
    color: var(--text-primary, rgba(255, 255, 255, 0.92));
    caret-color: rgba(165, 180, 252, 0.8);
  }

  .rt-search-input::placeholder {
    color: var(--text-muted, rgba(255, 255, 255, 0.25));
  }

  .rt-search-count {
    font-size: 0.65rem;
    color: var(--text-muted, rgba(255, 255, 255, 0.3));
    font-family: 'SF Mono', 'Fira Code', monospace;
    white-space: nowrap;
  }

  /* ── Summary bar ── */

  .rt-summary {
    display: flex;
    align-items: center;
    gap: 0;
    padding: 8px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    background: rgba(255, 255, 255, 0.02);
    flex-shrink: 0;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .rt-summary::-webkit-scrollbar { display: none; }

  .rt-stat {
    display: flex;
    flex-direction: column;
    gap: 1px;
    padding: 0 14px;
    min-width: fit-content;
  }

  .rt-stat:first-child { padding-left: 0; }

  .rt-stat-label {
    font-size: 0.625rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    font-weight: 500;
  }

  .rt-stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
    font-variant-numeric: tabular-nums;
  }

  .rt-status[data-status="succeeded"],
  .rt-status[data-status="done"],
  .rt-status[data-status="completed"] {
    color: rgba(74, 222, 128, 0.85);
  }

  .rt-status[data-status="running"] {
    color: rgba(96, 165, 250, 0.85);
  }

  .rt-status[data-status="failed"],
  .rt-status[data-status="error"] {
    color: rgba(248, 113, 113, 0.85);
  }

  .rt-stat-sep {
    width: 1px;
    height: 24px;
    background: rgba(255, 255, 255, 0.07);
    flex-shrink: 0;
  }

  /* ── Viewport ── */

  .rt-viewport {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .rt-viewport::-webkit-scrollbar { width: 3px; }
  .rt-viewport::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.08);
    border-radius: 2px;
  }

  /* ── Step list ── */

  .rt-list {
    list-style: none;
    margin: 0;
    padding: 8px 0;
    display: flex;
    flex-direction: column;
  }

  .rt-row {
    display: grid;
    grid-template-columns: 72px 20px 1fr auto;
    align-items: start;
    gap: 8px;
    padding: 7px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.03);
    transition: background 0.1s;
  }

  .rt-row:hover {
    background: rgba(255, 255, 255, 0.025);
  }

  .rt-row--error,
  .rt-row--error:hover {
    background: rgba(239, 68, 68, 0.04);
    border-bottom-color: rgba(239, 68, 68, 0.08);
  }

  /* ── Timestamp ── */

  .rt-ts {
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.625rem;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    padding-top: 2px;
    white-space: nowrap;
  }

  /* ── Icon ── */

  .rt-icon-wrap {
    display: flex;
    align-items: flex-start;
    padding-top: 2px;
    flex-shrink: 0;
  }

  .rt-row--tool_call .rt-icon-wrap { color: rgba(196, 181, 253, 0.7); }
  .rt-row--thinking .rt-icon-wrap  { color: rgba(147, 197, 253, 0.6); }
  .rt-row--message .rt-icon-wrap   { color: rgba(134, 239, 172, 0.6); }
  .rt-row--error .rt-icon-wrap     { color: rgba(248, 113, 113, 0.8); }
  .rt-row--system .rt-icon-wrap    { color: rgba(255, 255, 255, 0.3); }

  /* ── Content ── */

  .rt-content {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  /* Tool call */
  .rt-tool-header {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }

  .rt-tool-name {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
  }

  .rt-args-preview {
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.6875rem;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.4));
    background: rgba(255, 255, 255, 0.04);
    padding: 1px 5px;
    border-radius: 3px;
    max-width: 360px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .rt-err-badge {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: rgba(252, 100, 100, 0.9);
    background: rgba(239, 68, 68, 0.12);
    border: 1px solid rgba(239, 68, 68, 0.2);
    padding: 1px 5px;
    border-radius: 3px;
  }

  .rt-result-preview {
    font-size: 0.6875rem;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.38));
    margin: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .rt-expanded {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .rt-code {
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.6875rem;
    color: var(--text-secondary, rgba(255, 255, 255, 0.65));
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-sm, 5px);
    padding: 8px 10px;
    margin: 0;
    overflow-x: auto;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 200px;
    overflow-y: auto;
  }

  .rt-code--result {
    color: rgba(134, 239, 172, 0.75);
    background: rgba(74, 222, 128, 0.03);
    border-color: rgba(74, 222, 128, 0.1);
  }

  /* Thinking */
  .rt-thinking-collapsed,
  .rt-thinking-text {
    font-size: 0.6875rem;
    font-style: italic;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.4));
    margin: 0;
    line-height: 1.5;
  }

  .rt-thinking-text {
    color: rgba(147, 197, 253, 0.65);
    background: rgba(147, 197, 253, 0.03);
    padding: 6px 8px;
    border-radius: var(--radius-sm, 4px);
    border-left: 2px solid rgba(147, 197, 253, 0.2);
    white-space: pre-wrap;
    max-height: 200px;
    overflow-y: auto;
  }

  /* Message */
  .rt-msg-header {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .rt-msg-role {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    padding: 1px 5px;
    border-radius: 3px;
  }

  .rt-msg-role--user      { color: rgba(165, 243, 252, 0.8); background: rgba(6, 182, 212, 0.08); }
  .rt-msg-role--assistant { color: rgba(196, 181, 253, 0.8); background: rgba(139, 92, 246, 0.08); }
  .rt-msg-role--tool      { color: rgba(134, 239, 172, 0.8); background: rgba(74, 222, 128, 0.08); }

  .rt-msg-content {
    font-size: 0.75rem;
    color: var(--text-secondary, rgba(255, 255, 255, 0.7));
    margin: 0;
    line-height: 1.5;
  }

  /* Error */
  .rt-error-text {
    font-size: 0.75rem;
    color: rgba(252, 100, 100, 0.85);
    margin: 0;
    font-family: 'SF Mono', 'Fira Code', monospace;
  }

  /* System */
  .rt-system-text {
    font-size: 0.6875rem;
    color: var(--text-muted, rgba(255, 255, 255, 0.3));
    margin: 0;
    font-style: italic;
  }

  /* ── Row actions ── */

  .rt-row-actions {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
    padding-top: 1px;
    opacity: 0;
    transition: opacity 0.13s;
  }

  .rt-row:hover .rt-row-actions {
    opacity: 1;
  }

  .rt-cost-badge,
  .rt-dur-badge {
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.625rem;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    padding: 2px 5px;
    border-radius: 3px;
    white-space: nowrap;
  }

  .rt-expand-btn,
  .rt-copy-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    border-radius: 3px;
    background: transparent;
    border: 1px solid transparent;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    cursor: pointer;
    transition: background 0.12s, color 0.12s;
    flex-shrink: 0;
  }

  .rt-expand-btn:hover,
  .rt-copy-btn:hover {
    background: rgba(255, 255, 255, 0.07);
    border-color: rgba(255, 255, 255, 0.1);
    color: var(--text-secondary, rgba(255, 255, 255, 0.65));
  }

  /* ── Loading skeleton ── */

  .rt-skeleton-row {
    display: grid;
    grid-template-columns: 72px 20px 1fr auto;
    align-items: center;
    gap: 8px;
    padding: 10px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.03);
  }

  .rt-skeleton {
    height: 10px;
    background: rgba(255, 255, 255, 0.05);
    border-radius: 3px;
    animation: rt-shimmer 1.4s ease-in-out infinite;
  }

  .rt-skeleton--ts    { width: 100%; }
  .rt-skeleton--icon  { width: 14px; height: 14px; border-radius: 50%; }
  .rt-skeleton--badge { width: 40px; }

  @keyframes rt-shimmer {
    0%, 100% { opacity: 0.4; }
    50%       { opacity: 0.8; }
  }

  /* ── Error / empty states ── */

  .rt-error-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 48px 24px;
    color: rgba(252, 100, 100, 0.7);
  }

  .rt-error-msg {
    font-size: 0.75rem;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.4));
    text-align: center;
    margin: 0;
    max-width: 320px;
  }

  .rt-retry-btn {
    padding: 5px 14px;
    font-size: 0.75rem;
    font-weight: 500;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: var(--radius-sm, 5px);
    color: var(--text-secondary, rgba(255, 255, 255, 0.65));
    cursor: pointer;
    transition: background 0.13s;
  }

  .rt-retry-btn:hover {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text-primary, rgba(255, 255, 255, 0.9));
  }

  .rt-empty-state {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 48px 24px;
  }

  .rt-empty-msg {
    font-size: 0.75rem;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    margin: 0;
  }

  /* ── Scroll FAB ── */

  .rt-scroll-fab {
    position: absolute;
    bottom: 16px;
    right: 14px;
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.09);
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    border: 1px solid rgba(255, 255, 255, 0.13);
    color: rgba(255, 255, 255, 0.6);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: background 0.13s, transform 0.13s;
    z-index: 10;
  }

  .rt-scroll-fab:hover {
    background: rgba(255, 255, 255, 0.15);
    transform: translateY(-1px);
  }

  /* ── Spinner ── */

  .rt-spin {
    animation: rt-spin 0.75s linear infinite;
  }

  @keyframes rt-spin {
    to { transform: rotate(360deg); }
  }
</style>
