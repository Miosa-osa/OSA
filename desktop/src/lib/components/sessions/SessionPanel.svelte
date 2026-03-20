<script lang="ts">
  import { fly, fade } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { sessionsStore } from "$lib/stores/sessions.svelte";
  import SessionItem from "./SessionItem.svelte";

  // ── Filter ─────────────────────────────────────────────────────────────────

  let query = $state("");

  const filtered = $derived(
    query.trim()
      ? sessionsStore.sessions.filter((s) =>
          (s.title ?? "").toLowerCase().includes(query.trim().toLowerCase()),
        )
      : sessionsStore.sessions,
  );

  // ── Keyboard navigation ────────────────────────────────────────────────────

  let focusedIndex = $state<number>(-1);
  let listEl = $state<HTMLDivElement | null>(null);

  function focusItem(index: number) {
    focusedIndex = index;
    const items = listEl?.querySelectorAll<HTMLElement>("[role=option]");
    items?.[index]?.focus();
  }

  function handleListKeydown(e: KeyboardEvent) {
    if (!filtered.length) return;

    if (e.key === "ArrowDown") {
      e.preventDefault();
      focusItem(Math.min(focusedIndex + 1, filtered.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      focusItem(Math.max(focusedIndex - 1, 0));
    }
  }

  // ── New session ────────────────────────────────────────────────────────────

  let creating = $state(false);

  async function handleNew() {
    if (creating) return;
    creating = true;
    try {
      const session = await sessionsStore.createSession();
      if (session) {
        sessionsStore.switchSession(session.id);
        query = "";
        focusedIndex = 0;
      }
    } finally {
      creating = false;
    }
  }

  // ── Keyboard shortcut: Ctrl+Shift+S ───────────────────────────────────────

  function handleGlobalKey(e: KeyboardEvent) {
    if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === "S") {
      e.preventDefault();
      sessionsStore.toggle();
    }
    if (e.key === "Escape" && sessionsStore.isOpen) {
      sessionsStore.close();
    }
  }
</script>

<svelte:window onkeydown={handleGlobalKey} />

{#if sessionsStore.isOpen}
  <!-- Backdrop (click to close) -->
  <div
    class="backdrop"
    role="presentation"
    onclick={() => sessionsStore.close()}
    transition:fade={{ duration: 150 }}
  ></div>

  <!-- Panel -->
  <aside
    class="session-panel"
    aria-label="Session browser"
    transition:fly={{ x: -240, duration: 260, easing: cubicOut }}
  >
    <!-- ── Header ─────────────────────────────────────────────────────────── -->
    <header class="panel-header">
      <h2 class="panel-title">Sessions</h2>
      <button
        class="new-btn"
        onclick={handleNew}
        disabled={creating}
        aria-label="New session"
        title="New session"
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.5v15m7.5-7.5h-15" />
        </svg>
      </button>
    </header>

    <!-- ── Search ─────────────────────────────────────────────────────────── -->
    <div class="search-wrap">
      <div class="search-inner">
        <svg class="search-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
            d="M21 21l-5.197-5.197m0 0A7.5 7.5 0 105.196 5.196a7.5 7.5 0 0010.607 10.607z" />
        </svg>
        <input
          class="search-input"
          type="search"
          placeholder="Filter sessions…"
          bind:value={query}
          aria-label="Filter sessions"
          onkeydown={(e) => {
            if (e.key === "ArrowDown") {
              e.preventDefault();
              focusItem(0);
            }
          }}
        />
        {#if query}
          <button
            class="search-clear"
            onclick={() => (query = "")}
            aria-label="Clear filter"
          >
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        {/if}
      </div>
    </div>

    <!-- ── Divider ─────────────────────────────────────────────────────────── -->
    <div class="divider"></div>

    <!-- ── Error ──────────────────────────────────────────────────────────── -->
    {#if sessionsStore.error}
      <p class="error-msg" role="alert">{sessionsStore.error}</p>
    {/if}

    <!-- ── Session list ───────────────────────────────────────────────────── -->
    <div
      bind:this={listEl}
      class="session-list"
      role="listbox"
      aria-label="Sessions"
      aria-multiselectable="false"
      tabindex="0"
      onkeydown={handleListKeydown}
    >
      {#if sessionsStore.loading}
        <div class="loading-state" aria-live="polite" aria-busy="true">
          <span class="spinner" aria-hidden="true"></span>
          <span>Loading…</span>
        </div>
      {:else if filtered.length === 0}
        <div class="empty-state" aria-live="polite">
          {#if query}
            <p>No sessions match "{query}"</p>
          {:else}
            <p>No sessions yet.</p>
            <p class="empty-sub">Start chatting to create one!</p>
          {/if}
        </div>
      {:else}
        {#each filtered as session, i (session.id)}
          <SessionItem
            {session}
            isActive={sessionsStore.activeId === session.id}
            onSelect={(id) => {
              sessionsStore.switchSession(id);
              focusedIndex = i;
            }}
            onRename={(id, title) => sessionsStore.renameSession(id, title)}
            onDelete={(id) => sessionsStore.deleteSession(id)}
          />
        {/each}
      {/if}
    </div>

    <!-- ── Footer shortcut hint ───────────────────────────────────────────── -->
    <footer class="panel-footer">
      <kbd class="shortcut-hint">⌃⇧S</kbd>
      <span class="shortcut-label">toggle panel</span>
    </footer>
  </aside>
{/if}

<style>
  /* ── Backdrop ──────────────────────────────────────────────────────────── */
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: var(--z-fixed);
    /* no background color — panel overlaps, backdrop only captures clicks */
  }

  /* ── Panel ─────────────────────────────────────────────────────────────── */
  .session-panel {
    position: fixed;
    top: 0;
    /* sits right of the sidebar; sidebar is always ≥56px */
    left: var(--sidebar-collapsed-width);
    height: 100dvh;
    width: 240px;
    z-index: calc(var(--z-fixed) + 1);

    display: flex;
    flex-direction: column;

    background: rgba(14, 14, 16, 0.88);
    backdrop-filter: blur(28px) saturate(160%);
    -webkit-backdrop-filter: blur(28px) saturate(160%);
    border-right: 1px solid rgba(255, 255, 255, 0.08);
    box-shadow: 4px 0 24px rgba(0, 0, 0, 0.4);
  }

  /* ── Header ────────────────────────────────────────────────────────────── */
  .panel-header {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 16px 14px 12px;
  }

  .panel-title {
    font-size: 13px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--text-tertiary);
  }

  .new-btn {
    width: 26px;
    height: 26px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid var(--border-default);
    color: var(--text-secondary);
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
    flex-shrink: 0;
  }

  .new-btn:hover {
    background: rgba(59, 130, 246, 0.15);
    border-color: rgba(59, 130, 246, 0.3);
    color: var(--accent-primary);
  }

  .new-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* ── Search ────────────────────────────────────────────────────────────── */
  .search-wrap {
    flex-shrink: 0;
    padding: 0 10px 10px;
  }

  .search-inner {
    position: relative;
    display: flex;
    align-items: center;
  }

  .search-icon {
    position: absolute;
    left: 9px;
    color: var(--text-tertiary);
    pointer-events: none;
    flex-shrink: 0;
  }

  .search-input {
    width: 100%;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-sm);
    padding: 6px 28px 6px 30px;
    font-size: 13px;
    color: var(--text-primary);
    outline: none;
    transition: border-color var(--transition-fast), box-shadow var(--transition-fast);
  }

  /* Remove default search decoration on webkit */
  .search-input::-webkit-search-decoration,
  .search-input::-webkit-search-cancel-button {
    -webkit-appearance: none;
  }

  .search-input::placeholder {
    color: var(--text-tertiary);
  }

  .search-input:focus {
    border-color: var(--border-focus);
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.12);
  }

  .search-clear {
    position: absolute;
    right: 6px;
    width: 20px;
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: none;
    color: var(--text-tertiary);
    cursor: pointer;
    border-radius: var(--radius-xs);
    transition: color var(--transition-fast), background var(--transition-fast);
  }

  .search-clear:hover {
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.07);
  }

  /* ── Divider ───────────────────────────────────────────────────────────── */
  .divider {
    flex-shrink: 0;
    height: 1px;
    margin: 0 10px 8px;
    background: var(--border-default);
  }

  /* ── Error ─────────────────────────────────────────────────────────────── */
  .error-msg {
    flex-shrink: 0;
    margin: 0 10px 8px;
    padding: 8px 10px;
    background: rgba(239, 68, 68, 0.1);
    border: 1px solid rgba(239, 68, 68, 0.2);
    border-radius: var(--radius-sm);
    font-size: 12px;
    color: var(--accent-error);
  }

  /* ── Session list ──────────────────────────────────────────────────────── */
  .session-list {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    padding: 0 6px;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  /* Inherits global ::-webkit-scrollbar from app.css (6px, transparent track) */

  /* ── States ────────────────────────────────────────────────────────────── */
  .loading-state,
  .empty-state {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 32px 16px;
    color: var(--text-tertiary);
    font-size: 13px;
    text-align: center;
  }

  .empty-sub {
    font-size: 12px;
    color: var(--text-muted);
  }

  .spinner {
    display: block;
    width: 18px;
    height: 18px;
    border: 2px solid rgba(255, 255, 255, 0.1);
    border-top-color: var(--accent-primary);
    border-radius: 50%;
    animation: spin 600ms linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* ── Footer ────────────────────────────────────────────────────────────── */
  .panel-footer {
    flex-shrink: 0;
    padding: 10px 14px;
    display: flex;
    align-items: center;
    gap: 6px;
    border-top: 1px solid var(--border-default);
  }

  .shortcut-hint {
    font-family: var(--font-mono);
    font-size: 10px;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-xs);
    padding: 1px 5px;
  }

  .shortcut-label {
    font-size: 11px;
    color: var(--text-muted);
  }
</style>
