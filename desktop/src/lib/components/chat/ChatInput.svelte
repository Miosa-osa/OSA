<script module lang="ts">
  export type SlashCommandName =
    | 'clear' | 'help' | 'model' | 'sessions' | 'memory'
    | 'login' | 'logout' | 'status' | 'cost' | 'context'
    | 'tools' | 'agents' | 'tasks' | 'doctor' | 'version'
    | 'compact' | 'export' | 'plan' | 'coordinator'
    | 'effort' | 'fast' | 'skills' | 'new';
</script>

<script lang="ts">
  import { voiceStore } from '$lib/stores/voice.svelte';

  interface Props {
    disabled?: boolean;
    onSend: (text: string) => void;
    onCommand?: (cmd: SlashCommandName) => void;
    placeholder?: string;
    isListening?: boolean;
    onFilesAttach?: (files: FileList | File[]) => void;
    isAgentThinking?: boolean;
    currentModel?: string;
  }

  let {
    disabled = false,
    onSend,
    onCommand,
    placeholder = 'Message OSA… (Enter to send, Shift+Enter for newline)',
    isListening = $bindable(false),
    onFilesAttach,
    isAgentThinking = false,
    currentModel,
  }: Props = $props();

  let fileInputEl = $state<HTMLInputElement | null>(null);

  function triggerFilePicker() {
    fileInputEl?.click();
  }

  function handleFileInput(e: Event) {
    const input = e.target as HTMLInputElement;
    if (input.files && input.files.length > 0 && onFilesAttach) {
      onFilesAttach(input.files);
      input.value = '';
    }
  }

  let text = $state('');
  let textareaEl = $state<HTMLTextAreaElement | null>(null);
  let isFocused = $state(false);

  const canSend = $derived(!disabled && text.trim().length > 0);

  // Sync voiceStore.isListening → bindable prop (read isListening to satisfy TS)
  $effect(() => {
    const _prev = isListening;
    void _prev;
    isListening = voiceStore.isListening;
  });

  function send() {
    if (!canSend) return;
    const value = text.trim();
    text = '';
    if (textareaEl) textareaEl.style.height = 'auto';
    onSend(value);
  }

  function handleKeydown(e: KeyboardEvent) {
    // Slash menu navigation takes priority
    if (showSlashMenu) {
      handleSlashKeydown(e);
      if (e.defaultPrevented) return;
    }
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      if (showSlashMenu) {
        showSlashMenu = false;
      }
      send();
      return;
    }
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault();
      text = '';
      showSlashMenu = false;
      if (textareaEl) textareaEl.style.height = 'auto';
    }
  }

  function resizeTextarea() {
    if (!textareaEl) return;
    textareaEl.style.height = 'auto';
    textareaEl.style.height = `${Math.min(textareaEl.scrollHeight, 200)}px`;
  }

  // Voice — uses voiceStore which handles local recording + backend transcription
  function toggleVoice() {
    voiceStore.toggle((transcript) => {
      // Append transcribed text
      text = text ? `${text} ${transcript}` : transcript;
      resizeTextarea();
    });
  }

  // ── Slash command autocomplete ─────────────────────────────────────────────
  const SLASH_COMMANDS: { name: SlashCommandName; desc: string }[] = [
    { name: 'clear',       desc: 'Clear chat — start fresh session' },
    { name: 'new',         desc: 'Start a new session' },
    { name: 'help',        desc: 'Show available commands' },
    { name: 'model',       desc: 'Show or switch current model' },
    { name: 'sessions',    desc: 'List recent sessions' },
    { name: 'memory',      desc: 'Show memory entries' },
    { name: 'login',       desc: 'Sign in with Anthropic account' },
    { name: 'logout',      desc: 'Sign out of Anthropic' },
    { name: 'status',      desc: 'Show session status' },
    { name: 'cost',        desc: 'Show cost breakdown' },
    { name: 'context',     desc: 'Show context window usage' },
    { name: 'tools',       desc: 'List available tools' },
    { name: 'skills',      desc: 'List available skills' },
    { name: 'agents',      desc: 'List agent roles' },
    { name: 'tasks',       desc: 'Show current tasks' },
    { name: 'plan',        desc: 'Toggle plan mode' },
    { name: 'compact',     desc: 'Force context compaction' },
    { name: 'doctor',      desc: 'Run health check' },
    { name: 'version',     desc: 'Show version info' },
    { name: 'export',      desc: 'Export conversation as markdown' },
    { name: 'coordinator', desc: 'Toggle coordinator mode' },
    { name: 'effort',      desc: 'Set thinking effort level' },
    { name: 'fast',        desc: 'Toggle fast mode' },
  ];

  let showSlashMenu = $state(false);
  let slashFilter = $state('');
  let slashSelectedIndex = $state(0);

  const filteredSlashCommands = $derived(
    slashFilter
      ? SLASH_COMMANDS.filter(c => c.name.startsWith(slashFilter))
      : SLASH_COMMANDS
  );

  function handleInput() {
    resizeTextarea();

    // Show slash menu when text starts with "/" and cursor is right after it
    if (text.startsWith('/') && !text.includes(' ') && text.length <= 20) {
      showSlashMenu = true;
      slashFilter = text.slice(1).toLowerCase();
      slashSelectedIndex = 0;
    } else {
      showSlashMenu = false;
    }
  }

  function selectSlashCommand(cmd: { name: SlashCommandName; desc: string }) {
    // Clear the typed slash text and close the menu
    text = '';
    showSlashMenu = false;
    if (textareaEl) textareaEl.style.height = 'auto';
    textareaEl?.focus();
    // Delegate execution to the parent — don't send as a chat message
    onCommand?.(cmd.name);
  }

  function handleSlashKeydown(e: KeyboardEvent) {
    if (!showSlashMenu || filteredSlashCommands.length === 0) return;

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      slashSelectedIndex = (slashSelectedIndex + 1) % filteredSlashCommands.length;
      return;
    }
    if (e.key === 'ArrowUp') {
      e.preventDefault();
      slashSelectedIndex = (slashSelectedIndex - 1 + filteredSlashCommands.length) % filteredSlashCommands.length;
      return;
    }
    if (e.key === 'Tab' || (e.key === 'Enter' && showSlashMenu)) {
      e.preventDefault();
      selectSlashCommand(filteredSlashCommands[slashSelectedIndex]);
      return;
    }
    if (e.key === 'Escape') {
      e.preventDefault();
      showSlashMenu = false;
      return;
    }
  }

  // Show voice mode dropdown
  let showVoiceMenu = $state(false);

  function setVoiceProvider(provider: 'local' | 'groq' | 'openai' | 'browser') {
    voiceStore.setProvider(provider);
    showVoiceMenu = false;
  }
</script>

<div
  class="input-root"
  class:input-root--focused={isFocused}
  class:input-root--disabled={disabled}
>
  <!-- Voice status indicators -->
  {#if voiceStore.isTranscribing}
    <div class="interim-bar">
      <span class="interim-text">Transcribing...</span>
    </div>
  {:else if voiceStore.interimText}
    <div class="interim-bar">
      <span class="interim-text">{voiceStore.interimText}</span>
    </div>
  {/if}

  <!-- Voice error -->
  {#if voiceStore.error}
    <div class="voice-error">
      <span>{voiceStore.error}</span>
      <button class="voice-error-dismiss" onclick={() => (voiceStore.error = null)}>×</button>
    </div>
  {/if}

  <!-- Slash command autocomplete menu -->
  {#if showSlashMenu && filteredSlashCommands.length > 0}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <div class="slash-menu" role="listbox" aria-label="Slash commands">
      {#each filteredSlashCommands as cmd, i (cmd.name)}
        <button
          class="slash-item"
          class:slash-item--selected={i === slashSelectedIndex}
          role="option"
          aria-selected={i === slashSelectedIndex}
          onclick={() => selectSlashCommand(cmd)}
          onmouseenter={() => { slashSelectedIndex = i; }}
        >
          <span class="slash-name">/{cmd.name}</span>
          <span class="slash-desc">{cmd.desc}</span>
        </button>
      {/each}
    </div>
  {/if}

  <!-- Agent thinking indicator -->
  {#if isAgentThinking}
    <div class="thinking-bar" aria-live="polite">
      <span class="thinking-dot" aria-hidden="true"></span>
      <span class="thinking-text">Agent is thinking…</span>
    </div>
  {/if}

  <!-- Textarea -->
  <div class="textarea-row">
    <textarea
      bind:this={textareaEl}
      bind:value={text}
      {disabled}
      {placeholder}
      rows={1}
      class="input-textarea"
      oninput={handleInput}
      onkeydown={handleKeydown}
      onfocus={() => { isFocused = true; }}
      onblur={() => { isFocused = false; }}
      aria-label="Chat message input"
      aria-multiline="true"
    ></textarea>
  </div>

  <!-- Hidden file input -->
  <input
    bind:this={fileInputEl}
    type="file"
    multiple
    accept="image/*,text/*,.md,.json,.csv,.yaml,.yml,.toml,.py,.go,.rs,.svelte,.tsx,.jsx,.sh,.sql,.log,.xml,.html,.css,.js,.ts,.pdf"
    onchange={handleFileInput}
    class="sr-only"
    aria-hidden="true"
    tabindex={-1}
  />

  <!-- Toolbar -->
  <div class="toolbar">
    <div class="toolbar-left">
      <!-- Attach files -->
      <button
        class="toolbar-btn"
        onclick={triggerFilePicker}
        {disabled}
        aria-label="Attach files"
        title="Attach files"
      >
        <svg
          width="15"
          height="15"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M21.44 11.05l-9.19 9.19a6 6 0 01-8.49-8.49l9.19-9.19a4 4 0 015.66 5.66l-9.2 9.19a2 2 0 01-2.83-2.83l8.49-8.48"/>
        </svg>
      </button>

      <!-- Voice input — always available (local recording works everywhere) -->
      <div class="voice-group">
        <button
          class="toolbar-btn"
          class:toolbar-btn--active={voiceStore.isListening}
          onclick={toggleVoice}
          {disabled}
          aria-label={voiceStore.isListening ? 'Stop voice input' : 'Start voice input'}
          title={voiceStore.isListening ? 'Stop listening' : `Voice input (${voiceStore.provider})`}
        >
          <svg
            width="15"
            height="15"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            aria-hidden="true"
          >
            <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
            <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
            <line x1="12" y1="19" x2="12" y2="23" />
            <line x1="8" y1="23" x2="16" y2="23" />
          </svg>
        </button>

        <!-- Voice mode selector (tiny dropdown) -->
        <button
          class="voice-mode-btn"
          onclick={() => (showVoiceMenu = !showVoiceMenu)}
          title="Voice mode"
          aria-label="Change voice mode"
        >
          <svg width="8" height="8" viewBox="0 0 8 8" fill="none" aria-hidden="true">
            <path d="M1 3L4 6L7 3" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/>
          </svg>
        </button>

        {#if showVoiceMenu}
          <!-- svelte-ignore a11y_click_events_have_key_events -->
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <div class="voice-menu" onclick={(e) => e.stopPropagation()}>
            <button
              class="voice-menu-item"
              class:voice-menu-item--active={voiceStore.provider === 'local'}
              onclick={() => setVoiceProvider('local')}
            >
              <span class="voice-menu-icon">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="2" ry="2"/><circle cx="12" cy="12" r="4"/></svg>
              </span>
              <div>
                <div class="voice-menu-label">Local (no key)</div>
                <div class="voice-menu-desc">{voiceStore.hasBrowserSpeech ? 'Live transcript' : 'Not available'}</div>
              </div>
            </button>
            <button
              class="voice-menu-item"
              class:voice-menu-item--active={voiceStore.provider === 'groq'}
              onclick={() => setVoiceProvider('groq')}
            >
              <span class="voice-menu-icon">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>
              </span>
              <div>
                <div class="voice-menu-label">Groq Whisper</div>
                <div class="voice-menu-desc">{voiceStore.groqKey ? 'Key set' : 'Add key in Settings'}</div>
              </div>
            </button>
            <button
              class="voice-menu-item"
              class:voice-menu-item--active={voiceStore.provider === 'openai'}
              onclick={() => setVoiceProvider('openai')}
            >
              <span class="voice-menu-icon">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 1a3 3 0 00-3 3v8a3 3 0 006 0V4a3 3 0 00-3-3z"/><path d="M19 10v2a7 7 0 01-14 0v-2"/></svg>
              </span>
              <div>
                <div class="voice-menu-label">OpenAI Whisper</div>
                <div class="voice-menu-desc">{voiceStore.openaiKey ? 'Key set' : 'Add key in Settings'}</div>
              </div>
            </button>
            <button
              class="voice-menu-item"
              class:voice-menu-item--active={voiceStore.provider === 'browser'}
              onclick={() => setVoiceProvider('browser')}
              disabled={!voiceStore.hasBrowserSpeech}
            >
              <span class="voice-menu-icon">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 014 10 15.3 15.3 0 01-4 10 15.3 15.3 0 01-4-10 15.3 15.3 0 014-10z"/></svg>
              </span>
              <div>
                <div class="voice-menu-label">Browser</div>
                <div class="voice-menu-desc">{voiceStore.hasBrowserSpeech ? 'Web Speech API' : 'Not available'}</div>
              </div>
            </button>
          </div>
        {/if}
      </div>

      <!-- Current model pill -->
      {#if currentModel}
        <span class="model-pill" aria-label="Current model: {currentModel}">{currentModel}</span>
      {/if}
    </div>

    <div class="toolbar-right">
      <span class="shortcut-hint" aria-hidden="true">⌘K clear</span>

      <!-- Character count -->
      {#if text.length > 0}
        <span class="char-count" aria-label="{text.length} characters">{text.length}</span>
      {/if}
      <button
        class="send-btn"
        onclick={send}
        disabled={!canSend}
        aria-label="Send message"
        title="Send (Enter)"
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M12 19V5" />
          <path d="M5 12l7-7 7 7" />
        </svg>
      </button>
    </div>
  </div>
</div>

<style>
  .input-root {
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: rgba(255, 255, 255, 0.03);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    transition:
      border-color 0.15s,
      box-shadow 0.15s;
    overflow: visible;
    position: relative;
  }

  .input-root--focused {
    border-color: rgba(255, 255, 255, 0.18);
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06) inset;
  }

  .input-root--disabled {
    opacity: 0.5;
    pointer-events: none;
  }

  /* Interim voice text */
  .interim-bar {
    padding: 4px 14px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  }

  .interim-text {
    font-size: 0.8125rem;
    color: rgba(255, 255, 255, 0.4);
    font-style: italic;
  }

  /* Voice error */
  .voice-error {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 4px 14px;
    font-size: 0.75rem;
    color: rgba(251, 191, 36, 0.8);
    background: rgba(251, 191, 36, 0.06);
    border-bottom: 1px solid rgba(251, 191, 36, 0.1);
  }

  .voice-error-dismiss {
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.4);
    cursor: pointer;
    font-size: 1rem;
    padding: 0 4px;
  }

  /* Textarea */
  .textarea-row {
    padding: 12px 14px 4px;
  }

  .input-textarea {
    width: 100%;
    min-height: 44px;
    max-height: 200px;
    background: transparent;
    border: none;
    outline: none;
    resize: none;
    color: rgba(255, 255, 255, 0.9);
    font-size: 0.9375rem;
    line-height: 1.6;
    font-family: inherit;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
    display: block;
  }

  .input-textarea::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  /* Toolbar */
  .toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 6px 10px 10px;
  }

  .toolbar-left,
  .toolbar-right {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .voice-group {
    display: flex;
    align-items: center;
    position: relative;
  }

  .toolbar-btn {
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: none;
    border: none;
    border-radius: 6px;
    color: rgba(255, 255, 255, 0.35);
    cursor: pointer;
    transition:
      color 0.12s,
      background 0.12s;
  }

  .toolbar-btn:hover {
    color: rgba(255, 255, 255, 0.7);
    background: rgba(255, 255, 255, 0.07);
  }

  .toolbar-btn--active {
    color: #f87171;
    animation: pulse-opacity 1s ease-in-out infinite;
  }

  .voice-mode-btn {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.2);
    cursor: pointer;
    border-radius: 4px;
    margin-left: -4px;
  }

  .voice-mode-btn:hover {
    color: rgba(255, 255, 255, 0.5);
    background: rgba(255, 255, 255, 0.05);
  }

  /* Voice mode dropdown */
  .voice-menu {
    position: absolute;
    bottom: 100%;
    left: 0;
    margin-bottom: 6px;
    background: rgba(20, 20, 24, 0.95);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    padding: 4px;
    min-width: 180px;
    z-index: 100;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
  }

  .voice-menu-item {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 8px 10px;
    background: none;
    border: none;
    border-radius: 7px;
    color: rgba(255, 255, 255, 0.7);
    cursor: pointer;
    text-align: left;
    transition: background 0.1s;
  }

  .voice-menu-item:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.08);
  }

  .voice-menu-item--active {
    background: rgba(255, 255, 255, 0.06);
  }

  .voice-menu-item:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .voice-menu-icon {
    font-size: 14px;
    flex-shrink: 0;
  }

  .voice-menu-label {
    font-size: 0.8125rem;
    font-weight: 500;
  }

  .voice-menu-desc {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.35);
  }

  @keyframes pulse-opacity {
    0%,
    100% {
      opacity: 1;
    }
    50% {
      opacity: 0.5;
    }
  }

  .shortcut-hint {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.15);
    letter-spacing: 0.02em;
    user-select: none;
    padding: 0 4px;
  }

  /* Foundation pill-icon send button — monochrome dark */
  .send-btn {
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 9999px;
    border: 1px solid rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.7);
    cursor: pointer;
    transition:
      background 0.15s,
      border-color 0.15s,
      color 0.15s,
      transform 0.1s;
    flex-shrink: 0;
  }

  .send-btn:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.14);
    border-color: rgba(255, 255, 255, 0.2);
    color: #fff;
  }

  .send-btn:active:not(:disabled) {
    transform: scale(0.94);
  }

  .send-btn:disabled {
    background: rgba(255, 255, 255, 0.03);
    border-color: rgba(255, 255, 255, 0.05);
    color: rgba(255, 255, 255, 0.12);
    cursor: not-allowed;
  }

  /* Slash command autocomplete */
  .slash-menu {
    position: absolute;
    bottom: 100%;
    left: 0;
    right: 0;
    margin-bottom: 4px;
    background: rgba(18, 18, 22, 0.97);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    padding: 4px;
    z-index: 200;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
    max-height: 280px;
    overflow-y: auto;
  }

  .slash-item {
    display: flex;
    align-items: center;
    gap: 12px;
    width: 100%;
    padding: 8px 12px;
    background: none;
    border: none;
    border-radius: 7px;
    color: rgba(255, 255, 255, 0.7);
    cursor: pointer;
    text-align: left;
    transition: background 0.08s;
  }

  .slash-item:hover,
  .slash-item--selected {
    background: rgba(255, 255, 255, 0.08);
  }

  .slash-name {
    font-size: 0.8125rem;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.85);
    font-family: var(--font-mono, monospace);
    min-width: 80px;
  }

  .slash-desc {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.35);
  }

  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border-width: 0;
  }

  /* Character count */
  .char-count {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.25);
    font-variant-numeric: tabular-nums;
    min-width: 24px;
    text-align: right;
  }

  /* Model pill */
  .model-pill {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.4);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 10px;
    padding: 1px 8px;
    white-space: nowrap;
    max-width: 120px;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  /* Agent thinking indicator */
  .thinking-bar {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 14px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  }

  .thinking-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(6, 182, 212, 0.7);
    animation: pulse 1.5s ease-in-out infinite;
  }

  .thinking-text {
    font-size: 0.8125rem;
    color: rgba(255, 255, 255, 0.35);
    font-style: italic;
  }

  @keyframes pulse {
    0%, 100% { opacity: 0.4; transform: scale(0.9); }
    50% { opacity: 1; transform: scale(1.1); }
  }
</style>
