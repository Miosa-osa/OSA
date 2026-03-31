<script lang="ts">
  import { fly } from 'svelte/transition';
  import { cubicOut } from 'svelte/easing';
  import { BASE_URL, API_PREFIX, getToken } from '$lib/api/client';

  interface Props {
    onClose: () => void;
    onSelectSession: (sessionId: string) => void;
  }

  let { onClose, onSelectSession }: Props = $props();

  interface SearchResult {
    session_id: string;
    title: string;
    content: string;
    role: string;
    created_at: string;
    highlight: string;
  }

  let query = $state('');
  let results = $state<SearchResult[]>([]);
  let searching = $state(false);
  let searchInput = $state<HTMLInputElement | null>(null);

  let debounceTimer: ReturnType<typeof setTimeout>;

  function handleInput() {
    clearTimeout(debounceTimer);
    if (!query.trim()) {
      results = [];
      return;
    }
    debounceTimer = setTimeout(search, 300);
  }

  async function search() {
    if (!query.trim()) return;
    searching = true;
    try {
      const token = getToken();
      const headers: Record<string, string> = { 'Accept': 'application/json' };
      if (token) headers['Authorization'] = `Bearer ${token}`;

      const res = await fetch(
        `${BASE_URL}${API_PREFIX}/sessions/search?q=${encodeURIComponent(query)}&limit=20`,
        { headers }
      );
      if (res.ok) {
        const data = await res.json();
        results = data.results || [];
      }
    } catch {
      // Search endpoint may not be available yet
    } finally {
      searching = false;
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      onClose();
    }
  }

  function formatDate(iso: string): string {
    try {
      const d = new Date(iso);
      const now = new Date();
      const diff = now.getTime() - d.getTime();
      const mins = Math.floor(diff / 60000);
      if (mins < 1) return 'just now';
      if (mins < 60) return `${mins}m ago`;
      const hours = Math.floor(mins / 60);
      if (hours < 24) return `${hours}h ago`;
      const days = Math.floor(hours / 24);
      if (days < 7) return `${days}d ago`;
      return d.toLocaleDateString();
    } catch {
      return '';
    }
  }

  $effect(() => {
    searchInput?.focus();
  });
</script>

<div
  class="search-panel"
  role="search"
  aria-label="Search conversations"
  onkeydown={handleKeydown}
  in:fly={{ y: -10, duration: 200, easing: cubicOut }}
  out:fly={{ y: -10, duration: 150 }}
>
  <div class="search-header">
    <svg class="search-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
      <circle cx="11" cy="11" r="8" />
      <path d="M21 21l-4.35-4.35" />
    </svg>
    <input
      bind:this={searchInput}
      bind:value={query}
      oninput={handleInput}
      placeholder="Search past conversations..."
      class="search-input"
      type="search"
      aria-label="Search query"
    />
    <button class="close-btn" onclick={onClose} aria-label="Close search">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
        <path d="M18 6L6 18M6 6l12 12" />
      </svg>
    </button>
  </div>

  {#if searching}
    <div class="search-status">Searching...</div>
  {/if}

  <div class="search-results">
    {#each results as result (result.session_id + result.created_at)}
      <button
        class="result-item"
        onclick={() => onSelectSession(result.session_id)}
      >
        <div class="result-meta">
          <span class="result-title">{result.title || 'Untitled'}</span>
          <span class="result-date">{formatDate(result.created_at)}</span>
        </div>
        <div class="result-role">{result.role}</div>
        <div class="result-content">{result.highlight || result.content}</div>
      </button>
    {/each}

    {#if results.length === 0 && query.trim() && !searching}
      <div class="no-results">No conversations found</div>
    {/if}
  </div>
</div>

<style>
  .search-panel {
    background: rgba(24, 24, 27, 0.98);
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
    max-height: 400px;
    display: flex;
    flex-direction: column;
  }

  .search-header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  }

  .search-icon {
    color: rgba(255, 255, 255, 0.3);
    flex-shrink: 0;
  }

  .search-input {
    flex: 1;
    background: none;
    border: none;
    outline: none;
    color: rgba(255, 255, 255, 0.9);
    font-size: 0.875rem;
    font-family: inherit;
  }

  .search-input::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  .close-btn {
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.3);
    cursor: pointer;
    padding: 4px;
    border-radius: 4px;
  }

  .close-btn:hover {
    color: rgba(255, 255, 255, 0.6);
    background: rgba(255, 255, 255, 0.06);
  }

  .search-status {
    padding: 8px 14px;
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.3);
  }

  .search-results {
    overflow-y: auto;
    flex: 1;
  }

  .result-item {
    display: block;
    width: 100%;
    text-align: left;
    padding: 10px 14px;
    border: none;
    background: none;
    color: inherit;
    cursor: pointer;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
  }

  .result-item:hover {
    background: rgba(255, 255, 255, 0.04);
  }

  .result-meta {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 2px;
  }

  .result-title {
    font-size: 0.8125rem;
    color: rgba(255, 255, 255, 0.8);
    font-weight: 500;
  }

  .result-date {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.25);
  }

  .result-role {
    font-size: 0.6875rem;
    color: rgba(6, 182, 212, 0.6);
    margin-bottom: 4px;
  }

  .result-content {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.4);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .no-results {
    padding: 24px 14px;
    text-align: center;
    font-size: 0.8125rem;
    color: rgba(255, 255, 255, 0.25);
  }
</style>
