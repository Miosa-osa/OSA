<script lang="ts">
  interface Props {
    fontSize: number;
    searchVisible: boolean;
    onIncreaseFontSize: () => void;
    onDecreaseFontSize: () => void;
    onToggleSearch: () => void;
    onClear: () => void;
  }

  let {
    fontSize,
    searchVisible,
    onIncreaseFontSize,
    onDecreaseFontSize,
    onToggleSearch,
    onClear,
  }: Props = $props();
</script>

<div class="ttb-toolbar">
  <!-- Search toggle -->
  <button
    class="ttb-btn"
    class:ttb-btn--active={searchVisible}
    onclick={onToggleSearch}
    aria-label="Toggle search (Ctrl+F)"
    title="Search  Ctrl+F"
  >
    <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
      <circle cx="5.5" cy="5.5" r="3.5" stroke="currentColor" stroke-width="1.3"/>
      <line x1="8.5" y1="8.5" x2="12" y2="12" stroke="currentColor" stroke-width="1.3"
            stroke-linecap="round"/>
    </svg>
  </button>

  <!-- Font size decrease -->
  <button
    class="ttb-btn"
    onclick={onDecreaseFontSize}
    aria-label="Decrease font size"
    title="Decrease font size"
  >
    <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
      <text x="1" y="11" fill="currentColor" font-size="9" font-family="monospace">A</text>
      <line x1="8" y1="8" x2="13" y2="8" stroke="currentColor" stroke-width="1.3"
            stroke-linecap="round"/>
    </svg>
  </button>

  <!-- Font size label -->
  <span class="ttb-label" aria-label="Font size">{fontSize}px</span>

  <!-- Font size increase -->
  <button
    class="ttb-btn"
    onclick={onIncreaseFontSize}
    aria-label="Increase font size"
    title="Increase font size"
  >
    <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
      <text x="1" y="11" fill="currentColor" font-size="9" font-family="monospace">A</text>
      <line x1="8" y1="8" x2="13" y2="8" stroke="currentColor" stroke-width="1.3"
            stroke-linecap="round"/>
      <line x1="10.5" y1="5.5" x2="10.5" y2="10.5" stroke="currentColor" stroke-width="1.3"
            stroke-linecap="round"/>
    </svg>
  </button>

  <!-- Divider -->
  <div class="ttb-divider" aria-hidden="true"></div>

  <!-- Clear -->
  <button
    class="ttb-btn"
    onclick={onClear}
    aria-label="Clear terminal"
    title="Clear terminal  Ctrl+L"
  >
    <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
      <path d="M2 4h10M5 4V2.5a.5.5 0 0 1 .5-.5h3a.5.5 0 0 1 .5.5V4M3 4l.7 7.2a.5.5 0 0 0 .5.3h5.6a.5.5 0 0 0 .5-.3L11 4"
            stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>
  </button>
</div>

<style>
  .ttb-toolbar {
    display: flex;
    align-items: center;
    gap: 2px;
  }

  .ttb-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border: none;
    background: transparent;
    color: rgba(255, 255, 255, 0.45);
    border-radius: 6px;
    cursor: pointer;
    transition: background 140ms ease, color 140ms ease;
  }

  .ttb-btn:hover {
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.85);
  }

  .ttb-btn:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }

  .ttb-btn--active {
    background: rgba(59, 130, 246, 0.18);
    color: #60a5fa;
  }

  .ttb-btn--active:hover {
    background: rgba(59, 130, 246, 0.25);
    color: #93c5fd;
  }

  .ttb-label {
    font-size: 11px;
    color: rgba(255, 255, 255, 0.35);
    min-width: 28px;
    text-align: center;
    font-variant-numeric: tabular-nums;
  }

  .ttb-divider {
    width: 1px;
    height: 16px;
    background: rgba(255, 255, 255, 0.08);
    margin: 0 4px;
  }
</style>
