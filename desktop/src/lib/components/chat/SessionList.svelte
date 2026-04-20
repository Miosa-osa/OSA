<!-- src/lib/components/chat/SessionList.svelte -->
<!-- Svelte 5 session sidebar: list sessions, create new, delete on hover -->
<script lang="ts">
  import { onMount } from 'svelte';
  import { fly, fade } from 'svelte/transition';
  import { chatStore } from '$lib/stores/chat.svelte';
  import type { Session } from '$lib/api/types';

  interface Props {
    /** Called when user wants to start a fresh session */
    onNewSession?: () => void;
    /** Called when user clicks an existing session */
    onSelectSession?: (sessionId: string) => void;
  }

  let { onNewSession, onSelectSession }: Props = $props();

  // Track which session row is being hovered (for delete button reveal)
  let hoveredId = $state<string | null>(null);
  // Track which session is being deleted (prevents double-click)
  let deletingId = $state<string | null>(null);

  // Derive a sorted, display-ready list from chatStore
  const sessions = $derived(chatStore.sessions);
  const activeId = $derived(chatStore.currentSession?.id ?? null);

  onMount(() => {
    chatStore.listSessions();
  });

  // ── Search / Filter ─────────────────────────────────────────────────────────
  let filterQuery = $state('');

  const filteredSessions = $derived(
    filterQuery.trim()
      ? sessions.filter(s => {
          const q = filterQuery.toLowerCase();
          const title = (s.title ?? '').toLowerCase();
          return title.includes(q) || s.id.toLowerCase().includes(q);
        })
      : sessions
  );

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function formatRelativeTime(isoDate: string | null): string {
    if (!isoDate) return '';
    const now = Date.now();
    const then = new Date(isoDate).getTime();
    const diffMs = now - then;
    const diffSec = Math.floor(diffMs / 1000);
    const diffMin = Math.floor(diffSec / 60);
    const diffHr = Math.floor(diffMin / 60);
    const diffDay = Math.floor(diffHr / 24);

    if (diffSec < 60) return 'just now';
    if (diffMin < 60) return `${diffMin}m ago`;
    if (diffHr < 24) return `${diffHr}h ago`;
    if (diffDay === 1) return 'yesterday';
    if (diffDay < 7) return `${diffDay}d ago`;
    return new Date(isoDate).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  }

  function getSessionTitle(session: Session, index: number): string {
    return session.title ?? `Chat ${sessions.length - index}`;
  }

  async function handleNewSession(): Promise<void> {
    if (onNewSession) {
      onNewSession();
    } else {
      const session = await chatStore.createSession();
      chatStore.currentSession = session;
      chatStore.messages = [];
    }
  }

  function handleSelectSession(session: Session): void {
    if (session.id === activeId) return;
    if (onSelectSession) {
      onSelectSession(session.id);
    } else {
      chatStore.loadSession(session.id);
    }
  }

  async function handleDeleteSession(event: MouseEvent, sessionId: string): Promise<void> {
    event.stopPropagation();
    if (deletingId === sessionId) return;
    deletingId = sessionId;
    try {
      await chatStore.deleteSession(sessionId);
    } finally {
      deletingId = null;
      hoveredId = null;
    }
  }
</script>

<aside class="session-list" aria-label="Chat sessions">
  <!-- Header: New Chat + collapse toggle -->
  <div class="session-list__header">
    <button
      class="new-chat-btn"
      onclick={handleNewSession}
      aria-label="Start a new chat session"
    >
      <svg
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <line x1="12" y1="5" x2="12" y2="19" />
        <line x1="5" y1="12" x2="19" y2="12" />
      </svg>
      <span>New Chat</span>
    </button>
  </div>

  <!-- Search filter -->
  {#if sessions.length > 3}
    <div class="session-list__search">
      <input
        type="text"
        bind:value={filterQuery}
        placeholder="Filter sessions..."
        class="session-filter-input"
        aria-label="Filter sessions"
      />
    </div>
  {/if}

  <!-- Session count label -->
  {#if filteredSessions.length > 0}
    <div class="session-list__label" aria-hidden="true">
      Recent — {filteredSessions.length}{filterQuery ? ` of ${sessions.length}` : ''}
    </div>
  {/if}

  <!-- Loading state -->
  {#if chatStore.isLoadingSessions && sessions.length === 0}
    <div class="session-list__loading" aria-live="polite" aria-label="Loading sessions">
      <span class="loading-dot"></span>
      <span class="loading-dot"></span>
      <span class="loading-dot"></span>
    </div>
  {/if}

  <!-- Empty state -->
  {#if !chatStore.isLoadingSessions && filteredSessions.length === 0 && filterQuery}
    <div class="session-list__empty" transition:fade={{ duration: 200 }}>
      <p>No matching sessions</p>
    </div>
  {:else if !chatStore.isLoadingSessions && sessions.length === 0}
    <div class="session-list__empty" transition:fade={{ duration: 200 }}>
      <p>No past sessions</p>
      <p class="session-list__empty-hint">Start a conversation above</p>
    </div>
  {/if}

  <!-- Sessions -->
  <ul class="session-list__items" role="list">
    {#each filteredSessions as session, index (session.id)}
      <li
        class="session-item"
        class:session-item--active={session.id === activeId}
        onmouseenter={() => { hoveredId = session.id; }}
        onmouseleave={() => { hoveredId = null; }}
        transition:fly={{ x: -12, duration: 160, delay: index * 20 }}
      >
        <button
          class="session-item__btn"
          onclick={() => handleSelectSession(session)}
          aria-label="Load session: {getSessionTitle(session, index)}"
          aria-current={session.id === activeId ? 'true' : undefined}
        >
          <!-- Active indicator dot -->
          {#if session.id === activeId}
            <span class="active-dot" aria-hidden="true"></span>
          {/if}

          <!-- Title and meta -->
          <div class="session-item__body">
            <span class="session-item__title">{getSessionTitle(session, index)}</span>
            <div class="session-item__meta">
              {#if session.created_at}
                <time
                  class="session-item__time"
                  datetime={session.created_at}
                  title={new Date(session.created_at).toLocaleString()}
                >
                  {formatRelativeTime(session.created_at)}
                </time>
              {/if}
              {#if session.message_count > 0}
                <span class="session-item__count" aria-label="{session.message_count} messages">
                  {session.message_count}
                </span>
              {/if}
            </div>
          </div>
        </button>

        <!-- Delete button — revealed on hover -->
        {#if hoveredId === session.id}
          <button
            class="session-item__delete"
            onclick={(e) => handleDeleteSession(e, session.id)}
            disabled={deletingId === session.id}
            aria-label="Delete session: {getSessionTitle(session, index)}"
            transition:fade={{ duration: 100 }}
          >
            {#if deletingId === session.id}
              <svg
                width="12"
                height="12"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
                class="spin"
              >
                <path d="M21 12a9 9 0 11-6.219-8.56" />
              </svg>
            {:else}
              <svg
                width="12"
                height="12"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <line x1="18" y1="6" x2="6" y2="18" />
                <line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            {/if}
          </button>
        {/if}
      </li>
    {/each}
  </ul>
</aside>

<style>
  .session-list__search {
    padding: 6px 12px;
    flex-shrink: 0;
  }

  .session-filter-input {
    width: 100%;
    padding: 6px 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 6px;
    color: rgba(255, 255, 255, 0.8);
    font-size: 0.75rem;
    font-family: inherit;
    outline: none;
    transition: border-color 0.15s;
  }

  .session-filter-input::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  .session-filter-input:focus {
    border-color: rgba(255, 255, 255, 0.16);
  }

  .session-list {
    width: 280px;
    flex-shrink: 0;
    height: 100%;
    display: flex;
    flex-direction: column;
    background: rgba(8, 8, 10, 0.85);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border-right: 1px solid rgba(255, 255, 255, 0.06);
    overflow: hidden;
  }

  /* ── Header ── */

  .session-list__header {
    padding: 14px 12px 10px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .new-chat-btn {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 9px 14px;
    background: rgba(59, 130, 246, 0.12);
    border: 1px solid rgba(59, 130, 246, 0.25);
    border-radius: 8px;
    color: rgba(147, 197, 253, 0.9);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s, color 0.15s;
  }

  .new-chat-btn:hover {
    background: rgba(59, 130, 246, 0.2);
    border-color: rgba(59, 130, 246, 0.45);
    color: rgba(191, 219, 254, 1);
  }

  .new-chat-btn:active {
    background: rgba(59, 130, 246, 0.28);
  }

  /* ── Label ── */

  .session-list__label {
    padding: 4px 14px 6px;
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.25);
    flex-shrink: 0;
  }

  /* ── Loading ── */

  .session-list__loading {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 5px;
    padding: 32px 0;
    flex-shrink: 0;
  }

  .loading-dot {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.2);
    animation: pulse-dot 1.2s ease-in-out infinite;
  }

  .loading-dot:nth-child(2) { animation-delay: 0.2s; }
  .loading-dot:nth-child(3) { animation-delay: 0.4s; }

  @keyframes pulse-dot {
    0%, 80%, 100% { opacity: 0.2; transform: scale(0.8); }
    40% { opacity: 0.8; transform: scale(1); }
  }

  /* ── Empty ── */

  .session-list__empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;
    padding: 40px 16px;
    color: rgba(255, 255, 255, 0.25);
    font-size: 12px;
    text-align: center;
    flex-shrink: 0;
  }

  .session-list__empty p {
    margin: 0;
  }

  .session-list__empty-hint {
    font-size: 11px;
    color: rgba(255, 255, 255, 0.14);
  }

  /* ── Items list ── */

  .session-list__items {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    padding: 4px 8px 16px;
    margin: 0;
    list-style: none;
    display: flex;
    flex-direction: column;
    gap: 2px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .session-list__items::-webkit-scrollbar {
    width: 3px;
  }

  .session-list__items::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.08);
    border-radius: 2px;
  }

  /* ── Single session row ── */

  .session-item {
    position: relative;
    display: flex;
    align-items: center;
    border-radius: 8px;
    transition: background 0.12s;
  }

  .session-item:hover {
    background: rgba(255, 255, 255, 0.04);
  }

  /* Active session: blue left accent border */
  .session-item--active {
    background: rgba(59, 130, 246, 0.07);
    border-left: 2px solid rgba(59, 130, 246, 0.7);
  }

  .session-item--active:hover {
    background: rgba(59, 130, 246, 0.1);
  }

  .session-item__btn {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 10px;
    background: none;
    border: none;
    cursor: pointer;
    text-align: left;
    color: inherit;
    border-radius: 8px;
    overflow: hidden;
  }

  /* Remove double left padding when active border is showing */
  .session-item--active .session-item__btn {
    padding-left: 8px;
  }

  /* Active indicator dot */
  .active-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(59, 130, 246, 0.9);
    box-shadow: 0 0 6px rgba(59, 130, 246, 0.6);
    flex-shrink: 0;
  }

  .session-item__body {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .session-item__title {
    font-size: 12.5px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.75);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    line-height: 1.4;
  }

  .session-item--active .session-item__title {
    color: rgba(255, 255, 255, 0.92);
  }

  .session-item__meta {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .session-item__time {
    font-size: 10.5px;
    color: rgba(255, 255, 255, 0.28);
    white-space: nowrap;
  }

  .session-item__count {
    font-size: 10px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.2);
    background: rgba(255, 255, 255, 0.06);
    border-radius: 9999px;
    padding: 1px 6px;
    white-space: nowrap;
  }

  /* ── Delete button ── */

  .session-item__delete {
    flex-shrink: 0;
    width: 24px;
    height: 24px;
    margin-right: 6px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: none;
    border: none;
    border-radius: 5px;
    color: rgba(255, 255, 255, 0.25);
    cursor: pointer;
    transition: color 0.12s, background 0.12s;
  }

  .session-item__delete:hover {
    color: rgba(239, 68, 68, 0.85);
    background: rgba(239, 68, 68, 0.1);
  }

  .session-item__delete:disabled {
    cursor: default;
    opacity: 0.5;
  }

  /* Spinner animation for delete in progress */
  .spin {
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
  }

</style>
