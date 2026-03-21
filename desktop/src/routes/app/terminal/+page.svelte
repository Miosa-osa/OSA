<script lang="ts">
  import XTerminal from '$lib/components/terminal/XTerminal.svelte';
  import TerminalToolbar from '$lib/components/terminal/TerminalToolbar.svelte';

  // ── State ─────────────────────────────────────────────────────────────────

  let fontSize = $state(13);
  let searchVisible = $state(false);
  let searchQuery = $state('');
  let searchInputEl = $state<HTMLInputElement | null>(null);
  let terminal = $state<ReturnType<typeof XTerminal> | null>(null);

  // ── Font size controls ────────────────────────────────────────────────────

  function increaseFontSize() {
    fontSize = Math.min(fontSize + 1, 24);
  }

  function decreaseFontSize() {
    fontSize = Math.max(fontSize - 1, 9);
  }

  // ── Search ────────────────────────────────────────────────────────────────

  function toggleSearch() {
    searchVisible = !searchVisible;
    if (searchVisible) {
      setTimeout(() => searchInputEl?.focus(), 50);
    } else {
      searchQuery = '';
      terminal?.focus();
    }
  }

  function handleSearchInput(e: Event) {
    const val = (e.target as HTMLInputElement).value;
    searchQuery = val;
    terminal?.search(val);
  }

  function searchNext() {
    terminal?.searchNext(searchQuery);
  }

  function searchPrev() {
    terminal?.searchPrev(searchQuery);
  }

  function closeSearch() {
    searchVisible = false;
    searchQuery = '';
    terminal?.focus();
  }

  function handleSearchKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape')                          { closeSearch(); return; }
    if (e.key === 'Enter')                           { e.shiftKey ? searchPrev() : searchNext(); return; }
    if (e.key === 'f' && (e.ctrlKey || e.metaKey))  { e.preventDefault(); closeSearch(); }
  }

  // ── Clear ─────────────────────────────────────────────────────────────────

  function clearTerminal() {
    terminal?.clear();
  }
</script>

<svelte:head>
  <title>Terminal — OSA</title>
</svelte:head>

<div class="terminal-page">
  <!-- Header bar -->
  <header class="term-header">
    <div class="term-header__left">
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
        <rect width="16" height="16" rx="3" fill="rgba(255,255,255,0.06)" />
        <path d="M3.5 5.5L6.5 8L3.5 10.5" stroke="rgba(255,255,255,0.6)" stroke-width="1.2"
              stroke-linecap="round" stroke-linejoin="round"/>
        <line x1="8" y1="10.5" x2="12" y2="10.5" stroke="rgba(255,255,255,0.4)"
              stroke-width="1.2" stroke-linecap="round"/>
      </svg>
      <span class="term-header__title">Terminal</span>
    </div>

    <TerminalToolbar
      {fontSize}
      {searchVisible}
      onIncreaseFontSize={increaseFontSize}
      onDecreaseFontSize={decreaseFontSize}
      onToggleSearch={toggleSearch}
      onClear={clearTerminal}
    />
  </header>

  <!-- Search bar -->
  {#if searchVisible}
    <div class="search-bar" role="search" aria-label="Terminal search">
      <svg class="search-icon" width="13" height="13" viewBox="0 0 13 13" fill="none" aria-hidden="true">
        <circle cx="5" cy="5" r="3.5" stroke="rgba(255,255,255,0.4)" stroke-width="1.2"/>
        <line x1="8" y1="8" x2="12" y2="12" stroke="rgba(255,255,255,0.4)" stroke-width="1.2"
              stroke-linecap="round"/>
      </svg>
      <input
        bind:this={searchInputEl}
        class="search-input"
        type="text"
        placeholder="Search terminal..."
        value={searchQuery}
        oninput={handleSearchInput}
        onkeydown={handleSearchKeydown}
        aria-label="Search terminal output"
        spellcheck="false"
        autocomplete="off"
      />
      <div class="search-actions">
        <button class="search-nav-btn" onclick={searchPrev} aria-label="Previous match">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path d="M3 7.5L6 4.5L9 7.5" stroke="currentColor" stroke-width="1.3"
                  stroke-linecap="round" stroke-linejoin="round"/>
          </svg>
        </button>
        <button class="search-nav-btn" onclick={searchNext} aria-label="Next match">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path d="M3 4.5L6 7.5L9 4.5" stroke="currentColor" stroke-width="1.3"
                  stroke-linecap="round" stroke-linejoin="round"/>
          </svg>
        </button>
        <button class="search-close-btn" onclick={closeSearch} aria-label="Close search">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path d="M2 2L10 10M10 2L2 10" stroke="currentColor" stroke-width="1.3"
                  stroke-linecap="round"/>
          </svg>
        </button>
      </div>
    </div>
  {/if}

  <!-- Terminal -->
  <XTerminal
    bind:this={terminal}
    bind:fontSize
    onToggleSearch={toggleSearch}
  />
</div>

<style>
  .terminal-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    width: 100%;
    background: #0a0a0c;
    overflow: hidden;
  }

  .term-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 12px;
    height: 40px;
    flex-shrink: 0;
    background: rgba(255, 255, 255, 0.04);
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
    user-select: none;
  }

  .term-header__left {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .term-header__title {
    font-size: 13px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.7);
    letter-spacing: 0.01em;
  }

  /* Search bar */
  .search-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    background: rgba(255, 255, 255, 0.04);
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
    flex-shrink: 0;
  }

  .search-icon {
    flex-shrink: 0;
  }

  .search-input {
    flex: 1;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 6px;
    padding: 4px 10px;
    font-size: 13px;
    font-family: var(--font-sans);
    color: rgba(255, 255, 255, 0.85);
    outline: none;
    min-width: 0;
    transition: border-color 140ms ease;
  }

  .search-input::placeholder {
    color: rgba(255, 255, 255, 0.25);
  }

  .search-input:focus {
    border-color: rgba(59, 130, 246, 0.5);
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.12);
  }

  .search-actions {
    display: flex;
    align-items: center;
    gap: 2px;
    flex-shrink: 0;
  }

  .search-nav-btn,
  .search-close-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border: none;
    background: transparent;
    color: rgba(255, 255, 255, 0.45);
    border-radius: 5px;
    cursor: pointer;
    transition: background 120ms ease, color 120ms ease;
  }

  .search-nav-btn:hover,
  .search-close-btn:hover {
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.85);
  }

  .search-nav-btn:focus-visible,
  .search-close-btn:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }
</style>
