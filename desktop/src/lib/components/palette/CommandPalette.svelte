<!-- src/lib/components/palette/CommandPalette.svelte -->
<!-- Spotlight-style command palette with grouped sections. Triggered by Cmd/Ctrl+K. -->
<script lang="ts">
  import { fly } from 'svelte/transition';
  import { paletteStore } from '$lib/stores/palette.svelte';
  import type { PaletteCommand, CommandCategory } from '$lib/stores/palette.svelte';
  import PaletteIcon from './PaletteIcon.svelte';

  // ── Input binding & keyboard handling ────────────────────────────────────────

  let inputEl = $state<HTMLInputElement | null>(null);

  $effect(() => {
    if (paletteStore.isOpen && inputEl) {
      requestAnimationFrame(() => inputEl?.focus());
    }
  });

  function handleKeyDown(e: KeyboardEvent) {
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        paletteStore.moveDown();
        scrollSelectedIntoView();
        break;
      case 'ArrowUp':
        e.preventDefault();
        paletteStore.moveUp();
        scrollSelectedIntoView();
        break;
      case 'Enter':
        e.preventDefault();
        void paletteStore.executeSelected();
        break;
      case 'Escape':
        e.preventDefault();
        paletteStore.close();
        break;
    }
  }

  function scrollSelectedIntoView() {
    requestAnimationFrame(() => {
      const el = document.querySelector<HTMLElement>('[data-palette-selected="true"]');
      el?.scrollIntoView({ block: 'nearest' });
    });
  }

  // ── Section config ────────────────────────────────────────────────────────────

  const CATEGORY_LABELS: Record<CommandCategory, string> = {
    recent: 'Recent',
    navigation: 'Navigation',
    actions: 'Actions',
    commands: 'Commands',
    search: 'Search Results',
  };

  const BADGE_COLORS: Record<string, string> = {
    Agent:   'badge--agent',
    Task:    'badge--task',
    Project: 'badge--project',
    Issue:   'badge--issue',
  };

  // ── Index helpers ─────────────────────────────────────────────────────────────

  function globalIndex(cmd: PaletteCommand): number {
    return paletteStore.flatFiltered.indexOf(cmd);
  }

  function isSelected(cmd: PaletteCommand): boolean {
    return globalIndex(cmd) === paletteStore.selectedIndex;
  }

  // ── Grouped sections for rendering ───────────────────────────────────────────

  interface Section {
    category: CommandCategory;
    label: string;
    items: PaletteCommand[];
  }

  const sections = $derived.by((): Section[] => {
    const g = paletteStore.grouped;
    const cats: CommandCategory[] = ['recent', 'navigation', 'actions', 'commands', 'search'];
    return cats
      .filter((cat) => g[cat].length > 0)
      .map((cat) => ({ category: cat, label: CATEGORY_LABELS[cat], items: g[cat] }));
  });

  const hasResults = $derived(paletteStore.totalVisible > 0);
  const queryLen = $derived(paletteStore.query.trim().length);
  const showSearchHint = $derived(queryLen > 0 && queryLen < 3);
  const charsLeft = $derived(3 - queryLen);
</script>

<!-- Backdrop -->
<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
<div class="cp-backdrop" onclick={() => paletteStore.close()} aria-hidden="true"></div>

<!-- Palette card -->
<div
  class="cp-card"
  role="dialog"
  aria-label="Command palette"
  aria-modal="true"
  tabindex="-1"
  transition:fly={{ y: -10, duration: 150, opacity: 0 }}
  onkeydown={handleKeyDown}
>
  <!-- Search input -->
  <div class="cp-search-row">
    <svg class="cp-search-icon" viewBox="0 0 20 20" fill="none" aria-hidden="true">
      <circle cx="8.5" cy="8.5" r="5.5" stroke="currentColor" stroke-width="1.5"/>
      <path d="M13.5 13.5L17 17" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
    </svg>
    <input
      bind:this={inputEl}
      type="text"
      class="cp-input"
      placeholder="Search commands, agents, tasks, projects..."
      autocomplete="off"
      autocorrect="off"
      spellcheck={false}
      value={paletteStore.query}
      oninput={(e) => paletteStore.setQuery((e.currentTarget as HTMLInputElement).value)}
      aria-label="Command search"
      aria-autocomplete="list"
      aria-controls="cp-results"
      aria-activedescendant={hasResults ? `cp-item-${paletteStore.selectedIndex}` : undefined}
    />
    <kbd class="cp-esc" aria-label="Press Escape to close">esc</kbd>
  </div>

  <div class="cp-divider"></div>

  <!-- Results -->
  <div class="cp-results" id="cp-results" role="listbox" aria-label="Command results">
    {#if showSearchHint}
      <div class="cp-search-hint" role="status">
        Type {charsLeft} more character{charsLeft === 1 ? '' : 's'} to search data
      </div>
    {/if}

    {#if hasResults}
      {#each sections as section (section.category)}
        <div class="cp-group" role="group" aria-label={section.label}>
          <div class="cp-group-label">{section.label}</div>
          {#each section.items as cmd (cmd.id)}
            {@const idx = globalIndex(cmd)}
            {@const selected = isSelected(cmd)}
            <button
              id="cp-item-{idx}"
              class="cp-item"
              class:cp-item--selected={selected}
              role="option"
              aria-selected={selected}
              data-palette-selected={selected}
              onclick={() => void paletteStore.execute(cmd)}
            >
              <span class="cp-item-icon">
                <PaletteIcon icon={cmd.icon} />
              </span>

              <span class="cp-item-text">
                <span class="cp-item-name">
                  {#if cmd.searchBadge}
                    <span
                      class="cp-badge {BADGE_COLORS[cmd.searchBadge] ?? 'badge--default'}"
                      aria-label="{cmd.searchBadge} result"
                    >{cmd.searchBadge}</span>
                  {/if}
                  {cmd.name}
                </span>
                {#if cmd.description}
                  <span class="cp-item-desc">{cmd.description}</span>
                {/if}
              </span>

              {#if cmd.shortcut}
                <kbd class="cp-item-shortcut">{cmd.shortcut}</kbd>
              {/if}
            </button>
          {/each}
        </div>
      {/each}
    {:else if !showSearchHint}
      <div class="cp-empty" role="status">
        {#if paletteStore.query}
          No results for "<span class="cp-empty-query">{paletteStore.query}</span>"
        {:else}
          Start typing to search commands
        {/if}
      </div>
    {/if}
  </div>

  <!-- Footer -->
  <div class="cp-footer" aria-hidden="true">
    <span><kbd>↑</kbd><kbd>↓</kbd> navigate</span>
    <span><kbd>↵</kbd> run</span>
    <span><kbd>esc</kbd> close</span>
    <span class="cp-footer-tip">3+ chars to search data</span>
  </div>
</div>

<style>
  /* ── Backdrop ─────────────────────────────────────────────────────────────── */
  .cp-backdrop {
    position: fixed;
    inset: 0;
    z-index: calc(var(--z-modal) - 1);
    background: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(2px);
    -webkit-backdrop-filter: blur(2px);
  }

  /* ── Card ─────────────────────────────────────────────────────────────────── */
  .cp-card {
    position: fixed;
    top: 18%;
    left: 50%;
    transform: translateX(-50%);
    z-index: var(--z-modal);
    width: min(580px, calc(100vw - 32px));
    max-height: 480px;
    display: flex;
    flex-direction: column;
    background: rgba(16, 16, 18, 0.95);
    backdrop-filter: blur(40px) saturate(1.8);
    -webkit-backdrop-filter: blur(40px) saturate(1.8);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 16px;
    box-shadow:
      0 24px 64px rgba(0, 0, 0, 0.7),
      0 4px 16px rgba(0, 0, 0, 0.4),
      inset 0 1px 0 rgba(255, 255, 255, 0.08);
    overflow: hidden;
  }

  /* ── Search row ───────────────────────────────────────────────────────────── */
  .cp-search-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 14px 16px;
    flex-shrink: 0;
  }

  .cp-search-icon {
    width: 18px;
    height: 18px;
    color: rgba(255, 255, 255, 0.35);
    flex-shrink: 0;
  }

  .cp-input {
    flex: 1;
    background: transparent;
    border: none;
    outline: none;
    color: rgba(255, 255, 255, 0.95);
    font-size: 15px;
    font-family: var(--font-sans);
    line-height: 1.4;
    caret-color: var(--accent-primary);
  }

  .cp-input::placeholder { color: rgba(255, 255, 255, 0.28); }

  .cp-esc {
    flex-shrink: 0;
    font-family: var(--font-sans);
    font-size: 11px;
    color: rgba(255, 255, 255, 0.3);
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 5px;
    padding: 2px 6px;
  }

  /* ── Divider ──────────────────────────────────────────────────────────────── */
  .cp-divider {
    height: 1px;
    background: linear-gradient(90deg, transparent, rgba(255,255,255,0.08), transparent);
    flex-shrink: 0;
  }

  /* ── Results ──────────────────────────────────────────────────────────────── */
  .cp-results {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    padding: 6px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255,255,255,0.12) transparent;
  }

  .cp-results::-webkit-scrollbar { width: 4px; }
  .cp-results::-webkit-scrollbar-thumb {
    background: rgba(255,255,255,0.12);
    border-radius: 9999px;
  }

  /* ── Search hint ──────────────────────────────────────────────────────────── */
  .cp-search-hint {
    padding: 10px 16px 4px;
    font-size: 12px;
    color: rgba(255,255,255,0.28);
    text-align: center;
  }

  /* ── Group ────────────────────────────────────────────────────────────────── */
  .cp-group { margin-bottom: 4px; }

  .cp-group-label {
    padding: 6px 10px 4px;
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: rgba(255,255,255,0.28);
    user-select: none;
  }

  /* ── Item ─────────────────────────────────────────────────────────────────── */
  .cp-item {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 8px 10px;
    border: none;
    border-radius: 8px;
    background: transparent;
    color: rgba(255,255,255,0.85);
    cursor: pointer;
    text-align: left;
    transition: background 80ms ease;
  }

  .cp-item:hover { background: rgba(255,255,255,0.08); }

  .cp-item--selected {
    background: rgba(59,130,246,0.18);
    color: rgba(255,255,255,0.95);
  }

  .cp-item--selected:hover { background: rgba(59,130,246,0.22); }

  /* ── Item: icon ───────────────────────────────────────────────────────────── */
  .cp-item-icon {
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    border-radius: 6px;
    background: rgba(255,255,255,0.06);
  }

  /* ── Item: text ───────────────────────────────────────────────────────────── */
  .cp-item-text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .cp-item-name {
    font-size: 14px;
    font-weight: 500;
    color: inherit;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .cp-item-desc {
    font-size: 12px;
    color: rgba(255,255,255,0.38);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .cp-item--selected .cp-item-desc { color: rgba(255,255,255,0.5); }

  /* ── Badges ───────────────────────────────────────────────────────────────── */
  .cp-badge {
    display: inline-flex;
    align-items: center;
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    padding: 1px 5px;
    border-radius: 4px;
    flex-shrink: 0;
    line-height: 1.6;
  }

  .badge--agent   { background: rgba(139,92,246,0.2);  color: rgba(167,139,250,0.9); border: 1px solid rgba(139,92,246,0.25); }
  .badge--task    { background: rgba(16,185,129,0.15); color: rgba(52,211,153,0.9);  border: 1px solid rgba(16,185,129,0.2); }
  .badge--project { background: rgba(59,130,246,0.15); color: rgba(96,165,250,0.9);  border: 1px solid rgba(59,130,246,0.2); }
  .badge--issue   { background: rgba(245,158,11,0.15); color: rgba(251,191,36,0.9);  border: 1px solid rgba(245,158,11,0.2); }
  .badge--default { background: rgba(255,255,255,0.08);color: rgba(255,255,255,0.5); border: 1px solid rgba(255,255,255,0.1); }

  /* ── Shortcut ─────────────────────────────────────────────────────────────── */
  .cp-item-shortcut {
    flex-shrink: 0;
    font-family: var(--font-sans);
    font-size: 11px;
    color: rgba(255,255,255,0.3);
    background: rgba(255,255,255,0.06);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 5px;
    padding: 2px 6px;
  }

  .cp-item--selected .cp-item-shortcut {
    color: rgba(59,130,246,0.8);
    background: rgba(59,130,246,0.1);
    border-color: rgba(59,130,246,0.2);
  }

  /* ── Empty state ──────────────────────────────────────────────────────────── */
  .cp-empty {
    padding: 28px 16px;
    text-align: center;
    font-size: 13px;
    color: rgba(255,255,255,0.3);
  }

  .cp-empty-query {
    color: rgba(255,255,255,0.55);
    font-style: italic;
  }

  /* ── Footer ───────────────────────────────────────────────────────────────── */
  .cp-footer {
    flex-shrink: 0;
    display: flex;
    gap: 16px;
    align-items: center;
    padding: 8px 16px;
    border-top: 1px solid rgba(255,255,255,0.05);
    font-size: 11px;
    color: rgba(255,255,255,0.22);
    user-select: none;
  }

  .cp-footer kbd {
    display: inline-block;
    font-family: var(--font-sans);
    font-size: 10px;
    background: rgba(255,255,255,0.07);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 4px;
    padding: 1px 4px;
    margin-right: 2px;
    color: rgba(255,255,255,0.35);
  }

  .cp-footer-tip {
    margin-left: auto;
    font-size: 10px;
    color: rgba(255,255,255,0.15);
    font-style: italic;
  }
</style>
