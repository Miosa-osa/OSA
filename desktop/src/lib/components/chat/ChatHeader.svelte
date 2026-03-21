<script lang="ts">
  import { modelsStore } from '$lib/stores/models.svelte';

  interface Props {
    onToggleHistory?: () => void;
    historyOpen?: boolean;
    isStreaming?: boolean;
  }

  let {
    onToggleHistory,
    historyOpen = true,
    isStreaming = false,
  }: Props = $props();

  let showModelMenu = $state(false);

  function toggleModelMenu() {
    showModelMenu = !showModelMenu;
  }

  function closeModelMenu() {
    showModelMenu = false;
  }

  async function selectModel(name: string) {
    closeModelMenu();
    await modelsStore.activateModel(name);
  }

  const currentModelLabel = $derived(modelsStore.current?.name ?? 'No model');

  $effect(() => {
    if (modelsStore.models.length === 0 && !modelsStore.loading) {
      modelsStore.fetchModels().catch(() => {});
    }
  });
</script>

<div class="ch-toolbar">
  <!-- History toggle -->
  {#if onToggleHistory}
    <button
      class="ch-btn"
      class:ch-btn--active={historyOpen}
      onclick={onToggleHistory}
      aria-label={historyOpen ? 'Hide chat history' : 'Show chat history'}
      title={historyOpen ? 'Hide history' : 'Show history'}
    >
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
        <line x1="9" y1="3" x2="9" y2="21" />
      </svg>
    </button>
  {/if}

  <div class="ch-spacer"></div>

  <!-- Streaming indicator -->
  {#if isStreaming}
    <span class="ch-streaming-pill" aria-live="polite">generating</span>
  {/if}

  <!-- Model selector dropdown -->
  <div class="ch-model-selector">
    {#if showModelMenu}
      <div class="ch-model-backdrop" role="presentation" onmousedown={closeModelMenu}></div>
    {/if}

    <button
      class="ch-model-btn"
      onclick={toggleModelMenu}
      aria-haspopup="listbox"
      aria-expanded={showModelMenu}
      aria-label="Select model"
    >
      {#if modelsStore.current}
        {@const providerColor = modelsStore.current.provider === 'anthropic' ? '#7c3aed'
          : modelsStore.current.provider === 'openai' ? '#16a34a'
          : modelsStore.current.provider === 'groq' ? '#f97316'
          : modelsStore.current.provider === 'openrouter' ? '#0ea5e9'
          : '#64748b'}
        <span class="ch-model-dot" style="background: {providerColor};"></span>
      {:else}
        <span class="ch-model-dot ch-model-dot--none"></span>
      {/if}

      <span class="ch-model-name">{currentModelLabel}</span>

      {#if modelsStore.switching}
        <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" class="ch-model-spin" aria-hidden="true">
          <path d="M21 12a9 9 0 1 1-6.219-8.56"/>
        </svg>
      {:else}
        <svg class="ch-model-chevron" class:ch-model-chevron--open={showModelMenu} width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <polyline points="6 9 12 15 18 9"></polyline>
        </svg>
      {/if}
    </button>

    {#if showModelMenu}
      <div class="ch-model-dropdown" role="listbox" aria-label="Available models">
        {#if modelsStore.loading}
          <div class="ch-model-empty">Loading models...</div>
        {:else if modelsStore.models.length === 0}
          <div class="ch-model-empty">No models available</div>
        {:else}
          {#each modelsStore.models as model (model.name + model.provider)}
            {@const providerColor = model.provider === 'anthropic' ? '#7c3aed'
              : model.provider === 'openai' ? '#16a34a'
              : model.provider === 'groq' ? '#f97316'
              : model.provider === 'openrouter' ? '#0ea5e9'
              : '#64748b'}
            <button
              class="ch-model-option"
              class:ch-model-option--active={model.active}
              class:ch-model-option--switching={modelsStore.switching === model.name}
              role="option"
              aria-selected={model.active}
              onclick={() => selectModel(model.name)}
            >
              <span class="ch-model-option-dot" style="background: {providerColor};"></span>
              <span class="ch-model-option-name">{model.name}</span>
              {#if model.active}
                <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" class="ch-model-check" aria-hidden="true">
                  <polyline points="20 6 9 17 4 12"></polyline>
                </svg>
              {/if}
            </button>
          {/each}
        {/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .ch-toolbar {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
    flex-shrink: 0;
  }

  .ch-btn {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 6px;
    color: rgba(255, 255, 255, 0.3);
    cursor: pointer;
    transition: color 150ms, background 150ms, border-color 150ms;
    flex-shrink: 0;
  }

  .ch-btn:hover {
    color: rgba(255, 255, 255, 0.7);
    background: rgba(255, 255, 255, 0.05);
    border-color: rgba(255, 255, 255, 0.15);
  }

  .ch-btn--active {
    color: rgba(59, 130, 246, 0.7);
    border-color: rgba(59, 130, 246, 0.25);
  }

  .ch-btn--active:hover {
    color: rgba(59, 130, 246, 0.9);
    background: rgba(59, 130, 246, 0.08);
    border-color: rgba(59, 130, 246, 0.35);
  }

  .ch-spacer {
    flex: 1;
  }

  .ch-streaming-pill {
    font-size: 0.625rem;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.3);
    animation: ch-pulse 1.5s ease-in-out infinite;
    padding: 0 4px;
  }

  @keyframes ch-pulse {
    0%, 100% { opacity: 0.4; }
    50% { opacity: 1; }
  }

  /* Model selector */
  .ch-model-selector {
    position: relative;
    flex-shrink: 0;
  }

  .ch-model-backdrop {
    position: fixed;
    inset: 0;
    z-index: 19;
  }

  .ch-model-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    font-size: 0.7rem;
    color: rgba(255, 255, 255, 0.45);
    cursor: pointer;
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 6px;
    text-align: left;
    transition: background 0.12s, color 0.12s, border-color 0.12s;
    max-width: 220px;
    height: 28px;
  }

  .ch-model-btn:hover {
    background: rgba(255, 255, 255, 0.05);
    color: rgba(255, 255, 255, 0.65);
    border-color: rgba(255, 255, 255, 0.15);
  }

  .ch-model-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
    opacity: 0.8;
  }

  .ch-model-dot--none {
    background: rgba(255, 255, 255, 0.2);
  }

  .ch-model-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: 0.68rem;
    letter-spacing: 0.01em;
  }

  .ch-model-chevron {
    flex-shrink: 0;
    transition: transform 0.15s ease;
    opacity: 0.5;
  }

  .ch-model-chevron--open {
    transform: rotate(180deg);
  }

  .ch-model-spin {
    animation: ch-spin 0.8s linear infinite;
  }

  @keyframes ch-spin {
    from { transform: rotate(0deg); }
    to   { transform: rotate(360deg); }
  }

  .ch-model-dropdown {
    position: absolute;
    top: calc(100% + 4px);
    right: 0;
    width: 260px;
    z-index: 20;
    background: rgba(18, 18, 22, 0.96);
    backdrop-filter: blur(20px) saturate(160%);
    -webkit-backdrop-filter: blur(20px) saturate(160%);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 10px;
    max-height: 300px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.1) transparent;
    box-shadow: 0 12px 32px rgba(0, 0, 0, 0.5);
    padding: 4px;
  }

  .ch-model-dropdown::-webkit-scrollbar {
    width: 4px;
  }

  .ch-model-dropdown::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 2px;
  }

  .ch-model-empty {
    padding: 12px 16px;
    font-size: 0.7rem;
    color: rgba(255, 255, 255, 0.3);
    font-style: italic;
  }

  .ch-model-option {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 7px 10px;
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.5);
    font-size: 0.7rem;
    font-family: var(--font-mono, ui-monospace, monospace);
    text-align: left;
    cursor: pointer;
    border-radius: 6px;
    transition: background 0.1s, color 0.1s;
  }

  .ch-model-option:hover {
    background: rgba(255, 255, 255, 0.06);
    color: rgba(255, 255, 255, 0.8);
  }

  .ch-model-option--active {
    color: rgba(255, 255, 255, 0.9);
    background: rgba(59, 130, 246, 0.08);
  }

  .ch-model-option--switching {
    opacity: 0.6;
    pointer-events: none;
  }

  .ch-model-option-dot {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    flex-shrink: 0;
    opacity: 0.75;
  }

  .ch-model-option-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }

  .ch-model-check {
    flex-shrink: 0;
    color: rgba(59, 130, 246, 0.7);
  }
</style>
