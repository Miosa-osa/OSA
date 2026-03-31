<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { fly } from 'svelte/transition';
  import { chatStore } from '$lib/stores/chat.svelte';
  import { BASE_URL, API_PREFIX } from '$lib/api/client';
  import { sessionsStore } from '$lib/stores/sessions.svelte';
  import { modelsStore } from '$lib/stores/models.svelte';
  import { restartBackend } from '$lib/utils/backend';
  import ChatHeader from './ChatHeader.svelte';
  import MessageList from './MessageList.svelte';
  import ChatInput from './ChatInput.svelte';
  import type { SlashCommandName } from './ChatInput.svelte';
  import type { ToolCallRef } from '$lib/api/types';
  import type { Message } from '$lib/api/types';
  import KeyboardShortcuts from '../layout/KeyboardShortcuts.svelte';
  import SearchPanel from './SearchPanel.svelte';

  interface Props {
    /** Session ID — passed from the route page after it resolves/creates one. */
    sessionId?: string;
    /** Toggle session history panel */
    onToggleHistory?: () => void;
    /** Whether the history panel is currently visible */
    historyOpen?: boolean;
  }

  let { sessionId = '', onToggleHistory, historyOpen = true }: Props = $props();

  // ── File attachment state ──────────────────────────────────────────────────
  interface AttachedFile {
    id: string;
    name: string;
    type: string;
    size: number;
    /** base64 data URL for images, raw text for text files */
    content: string;
    category: 'image' | 'text' | 'other';
  }

  let attachedFiles = $state<AttachedFile[]>([]);
  let isDragOver = $state(false);
  let dragCounter = $state(0);

  const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/svg+xml'];
  const TEXT_TYPES = ['text/plain', 'text/markdown', 'text/csv', 'text/html', 'text/css', 'text/javascript', 'application/json', 'application/xml'];

  function categorizeFile(type: string, name: string): 'image' | 'text' | 'other' {
    if (IMAGE_TYPES.includes(type)) return 'image';
    if (IMAGE_TYPES.some(t => type.startsWith(t.split('/')[0]) && type.includes(t.split('/')[1]))) return 'image';
    if (TEXT_TYPES.includes(type)) return 'text';
    const ext = name.split('.').pop()?.toLowerCase() ?? '';
    if (['png','jpg','jpeg','gif','webp','svg'].includes(ext)) return 'image';
    if (['txt','md','csv','html','css','js','ts','json','xml','yaml','yml','toml','py','go','rs','svelte','tsx','jsx','sh','sql','log'].includes(ext)) return 'text';
    return 'other';
  }

  async function processFiles(fileList: FileList | File[]) {
    const files = Array.from(fileList);
    for (const file of files) {
      const category = categorizeFile(file.type, file.name);
      const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

      if (category === 'image' || category === 'other') {
        const dataUrl = await readAsDataUrl(file);
        attachedFiles = [...attachedFiles, { id, name: file.name, type: file.type, size: file.size, content: dataUrl, category }];
      } else {
        const text = await file.text();
        attachedFiles = [...attachedFiles, { id, name: file.name, type: file.type, size: file.size, content: text, category }];
      }
    }
  }

  function readAsDataUrl(file: File): Promise<string> {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as string);
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
  }

  function removeFile(id: string) {
    attachedFiles = attachedFiles.filter(f => f.id !== id);
  }

  function formatFileSize(bytes: number): string {
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
  }

  function handleDragEnter(e: DragEvent) {
    e.preventDefault();
    dragCounter++;
    isDragOver = true;
  }

  function handleDragLeave(e: DragEvent) {
    e.preventDefault();
    dragCounter--;
    if (dragCounter <= 0) {
      isDragOver = false;
      dragCounter = 0;
    }
  }

  function handleDragOver(e: DragEvent) {
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
  }

  function handleDrop(e: DragEvent) {
    e.preventDefault();
    isDragOver = false;
    dragCounter = 0;
    if (e.dataTransfer?.files && e.dataTransfer.files.length > 0) {
      processFiles(e.dataTransfer.files);
    }
  }

  // ── Session sync ───────────────────────────────────────────────────────────
  $effect(() => {
    if (sessionId && chatStore.currentSession?.id !== sessionId) {
      chatStore.loadSession(sessionId).catch(() => {});
    }
  });

  // ── Streaming state derived for MessageList ────────────────────────────────
  const showTypingDots = $derived(
    chatStore.isStreaming &&
    chatStore.streaming.textBuffer.length === 0 &&
    chatStore.streaming.toolCalls.length === 0 &&
    chatStore.streaming.thinkingBuffer.length === 0
  );

  const streamingToolStates = $derived(
    chatStore.streaming.toolCalls.map((tc) => ({
      tool: tc as unknown as ToolCallRef,
      result: (tc as { result?: string }).result,
      isError: false,
      isRunning: !('result' in tc && tc.result !== undefined),
      isExpanded: false,
    }))
  );

  // ── Keyboard shortcuts overlay ──────────────────────────────────────────────
  let showShortcuts = $state(false);
  let showSearch = $state(false);

  function handleGlobalKeydown(e: KeyboardEvent) {
    if (e.key === '?' && document.activeElement?.tagName !== 'TEXTAREA' && document.activeElement?.tagName !== 'INPUT') {
      e.preventDefault();
      showShortcuts = !showShortcuts;
    }
    if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
      e.preventDefault();
      showSearch = !showSearch;
    }
  }

  function handleSearchSelectSession(sessionId: string) {
    showSearch = false;
    chatStore.loadSession(sessionId);
  }

  // ── Voice / orb ────────────────────────────────────────────────────────────
  let isVoiceListening = $state(false);
  const orbActive = $derived(chatStore.isStreaming || isVoiceListening);

  // ── Send ───────────────────────────────────────────────────────────────────
  function handleSend(text: string) {
    if (attachedFiles.length > 0) {
      const fileContext = attachedFiles.map(f => {
        if (f.category === 'text') {
          return `[Attached file: ${f.name} (${formatFileSize(f.size)})]\n\`\`\`\n${f.content.slice(0, 50000)}\n\`\`\``;
        } else if (f.category === 'image') {
          return `[Attached image: ${f.name} (${formatFileSize(f.size)})]`;
        }
        return `[Attached file: ${f.name} (${formatFileSize(f.size)})]`;
      }).join('\n\n');

      text = `${fileContext}\n\n${text}`;
      attachedFiles = [];
    }

    chatStore.sendMessage(text);
  }

  // ── Slash commands ─────────────────────────────────────────────────────────
  function injectSystemMessage(content: string): void {
    const msg: Message = {
      id: `system-${Date.now()}`,
      role: 'system',
      content,
      timestamp: new Date().toISOString(),
    };
    chatStore.messages = [...chatStore.messages, msg];
  }

  async function handleCommand(cmd: SlashCommandName): Promise<void> {
    switch (cmd) {
      case 'clear':
      case 'new': {
        if (chatStore.isStreaming) chatStore.cancelGeneration();
        const newSession = await chatStore.createSession();
        chatStore.currentSession = newSession;
        chatStore.messages = [];
        chatStore.pendingUserMessage = null;
        break;
      }

      case 'help': {
        const cmds = [
          '/clear', '/new', '/model', '/sessions', '/memory', '/login', '/logout',
          '/status', '/cost', '/context', '/tools', '/skills', '/agents', '/tasks',
          '/plan', '/compact', '/doctor', '/version', '/export', '/coordinator',
          '/effort', '/fast',
        ];
        injectSystemMessage(
          '**Available commands**\n\n' +
          cmds.map(c => `\`${c}\``).join(' · ')
        );
        break;
      }

      case 'model': {
        try {
          const res = await fetch(`${BASE_URL}/health`);
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const data = await res.json() as Record<string, unknown>;
          const active = modelsStore.current;
          const modelName = (data.model as string | undefined) ?? active?.name ?? 'unknown';
          const provider = (data.provider as string | undefined) ?? active?.provider ?? 'unknown';
          const contextWindow = active?.context_window
            ? `${(active.context_window / 1000).toFixed(0)}K context`
            : '';
          injectSystemMessage(
            `**Current model**\n\nModel: \`${modelName}\`\nProvider: ${provider}` +
            (contextWindow ? `\nContext: ${contextWindow}` : '') +
            `\nStatus: ${(data.status as string) ?? 'ok'}`
          );
        } catch {
          const active = modelsStore.current;
          injectSystemMessage(active
            ? `**Current model** (backend unreachable)\n\nModel: \`${active.name}\`\nProvider: ${active.provider}`
            : 'Could not reach backend. Is OSA running on port 9089?'
          );
        }
        break;
      }

      case 'sessions': {
        await chatStore.listSessions();
        const sessions = chatStore.sessions;
        if (sessions.length === 0) {
          injectSystemMessage('No sessions found.');
        } else {
          const lines = sessions.slice(0, 10).map((s, i) => {
            const label = s.title ?? `Session ${i + 1}`;
            const date = s.created_at ? new Date(s.created_at).toLocaleDateString() : 'unknown';
            const active = s.id === chatStore.currentSession?.id ? ' *(current)*' : '';
            return `${i + 1}. **${label}**${active} — ${s.message_count ?? 0} messages — ${date}`;
          }).join('\n');
          injectSystemMessage(`**Recent sessions** (${sessions.length} total)\n\n${lines}`);
        }
        sessionsStore.open();
        break;
      }

      case 'login': {
        // Check if current provider supports OAuth
        const currentProvider = modelsStore.current?.provider;
        if (currentProvider && currentProvider !== 'anthropic') {
          injectSystemMessage(
            `OAuth sign-in is only available for **Anthropic**.\n\n` +
            `Current provider: \`${currentProvider}\`\n` +
            `To use Anthropic, switch your provider in Settings or during onboarding.`
          );
          break;
        }

        try {
          const res = await fetch(`${BASE_URL}/onboarding/oauth/status`);
          const data = await res.json() as { connected: boolean };
          if (data.connected) {
            injectSystemMessage('Already signed in with Anthropic. Use `/logout` to disconnect.');
            break;
          }
        } catch { /* proceed to login */ }

        injectSystemMessage('Opening Anthropic sign-in in your browser...');
        try {
          const { openUrl } = await import('@tauri-apps/plugin-opener');
          const res = await fetch(`${BASE_URL}/onboarding/oauth/start`);
          const data = await res.json() as { authorize_url: string };
          await openUrl(data.authorize_url);

          for (let i = 0; i < 60; i++) {
            await new Promise(r => setTimeout(r, 2000));
            try {
              const status = await fetch(`${BASE_URL}/onboarding/oauth/status`);
              const d = await status.json() as { connected: boolean };
              if (d.connected) {
                injectSystemMessage('**Connected to Anthropic** ✓\n\nYour account is now linked.');
                return;
              }
            } catch { /* keep polling */ }
          }
          injectSystemMessage('OAuth timed out. Try `/login` again.');
        } catch (e) {
          injectSystemMessage(`Login failed: ${e instanceof Error ? e.message : 'unknown error'}`);
        }
        break;
      }

      case 'logout': {
        const prov = modelsStore.current?.provider;
        if (prov && prov !== 'anthropic') {
          injectSystemMessage('OAuth is only available for Anthropic.');
          break;
        }
        try {
          await fetch(`${BASE_URL}/onboarding/oauth/status`, { method: 'DELETE' });
          injectSystemMessage('Signed out of Anthropic.');
        } catch {
          injectSystemMessage('Failed to sign out. Backend may be offline.');
        }
        break;
      }

      case 'memory': {
        await fetchAndShowBackendCommand('memory');
        break;
      }

      // These commands fetch data from the backend and show results
      case 'status':
      case 'cost':
      case 'context':
      case 'tools':
      case 'skills':
      case 'agents':
      case 'tasks':
      case 'doctor':
      case 'version':
      case 'export':
      case 'compact':
      case 'plan':
      case 'coordinator':
      case 'effort':
      case 'fast': {
        await fetchAndShowBackendCommand(cmd);
        break;
      }
    }
  }

  /** Execute a slash command on the backend and display the result as a system message. */
  async function fetchAndShowBackendCommand(cmd: string): Promise<void> {
    try {
      const res = await fetch(`${BASE_URL}${API_PREFIX}/commands/execute`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ command: cmd, session_id: chatStore.currentSession?.id }),
      });
      if (res.ok) {
        const data = await res.json() as { output?: string; result?: string; error?: string };
        injectSystemMessage(data.output || data.result || data.error || `/${cmd} executed.`);
      } else {
        injectSystemMessage(`/${cmd} failed (HTTP ${res.status})`);
      }
    } catch {
      injectSystemMessage(`/${cmd} — backend unreachable`);
    }
  }

  // ── Command palette integration ─────────────────────────────────────────────
  function handlePaletteCommand(e: Event) {
    const detail = (e as CustomEvent<{ command: string }>).detail;
    if (!detail?.command) return;
    // All commands route through handleCommand — never send as chat text
    void handleCommand(detail.command as SlashCommandName);
  }

  onMount(() => {
    window.addEventListener('osa:insert-command', handlePaletteCommand);
    return () => window.removeEventListener('osa:insert-command', handlePaletteCommand);
  });

  onDestroy(() => {
    if (chatStore.isStreaming) {
      chatStore.cancelGeneration();
    }
  });
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<svelte:window onkeydown={handleGlobalKeydown} />

{#if showShortcuts}
  <KeyboardShortcuts onClose={() => showShortcuts = false} />
{/if}

<div
  class="chat-root"
  ondragenter={handleDragEnter}
  ondragleave={handleDragLeave}
  ondragover={handleDragOver}
  ondrop={handleDrop}
  role="region"
>
  <!-- Drag overlay -->
  {#if isDragOver}
    <div class="chat-drop-overlay" transition:fly={{ duration: 150, y: 8 }}>
      <div class="chat-drop-inner">
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/>
          <polyline points="17 8 12 3 7 8"/>
          <line x1="12" y1="3" x2="12" y2="15"/>
        </svg>
        <span class="chat-drop-text">Drop files here</span>
        <span class="chat-drop-hint">Images, text, code, documents</span>
      </div>
    </div>
  {/if}

  <!-- Connection status banner -->
  {#if chatStore.error}
    <div class="chat-conn-banner" role="status">
      <span class="chat-conn-dot"></span>
      <span class="chat-conn-text">Backend offline</span>
      <span class="chat-conn-hint">Start OSA backend on port 9089</span>
      <button
        class="chat-restart-btn"
        onclick={() => { restartBackend().catch(() => {}); }}
        aria-label="Restart backend"
      >
        Restart
      </button>
    </div>
  {/if}

  <!-- Search panel -->
  {#if showSearch}
    <SearchPanel
      onClose={() => showSearch = false}
      onSelectSession={handleSearchSelectSession}
    />
  {/if}

  <!-- Header: history toggle + model selector -->
  <ChatHeader
    {onToggleHistory}
    {historyOpen}
    isStreaming={chatStore.isStreaming}
  />

  <!-- Message list (owns scroll, orb, FAB) -->
  <MessageList
    messages={chatStore.messages}
    pendingUserMessage={chatStore.pendingUserMessage}
    isStreaming={chatStore.isStreaming}
    streamingText={chatStore.streaming.textBuffer}
    streamingThinking={chatStore.streaming.thinkingBuffer}
    {streamingToolStates}
    {showTypingDots}
    {orbActive}
  />

  <!-- Attached files bar -->
  {#if attachedFiles.length > 0}
    <div class="chat-attachments">
      {#each attachedFiles as file (file.id)}
        <div class="chat-chip" title={file.name}>
          {#if file.category === 'image'}
            <img src={file.content} alt={file.name} class="chat-chip-thumb" />
          {:else}
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/>
              <polyline points="14 2 14 8 20 8"/>
            </svg>
          {/if}
          <span class="chat-chip-name">{file.name}</span>
          <span class="chat-chip-size">{formatFileSize(file.size)}</span>
          <button
            class="chat-chip-remove"
            onclick={() => removeFile(file.id)}
            aria-label="Remove {file.name}"
          >
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
          </button>
        </div>
      {/each}
    </div>
  {/if}

  <!-- Input dock -->
  <div class="chat-input-dock">
    <ChatInput
      disabled={chatStore.isStreaming}
      onSend={handleSend}
      onCommand={handleCommand}
      bind:isListening={isVoiceListening}
      onFilesAttach={processFiles}
      isAgentThinking={chatStore.isStreaming}
      currentModel={modelsStore.current?.name}
    />
  </div>
</div>

<style>
  .chat-root {
    position: relative;
    display: flex;
    flex-direction: column;
    height: 100%;
    background: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(24px) saturate(180%);
    -webkit-backdrop-filter: blur(24px) saturate(180%);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 16px;
    overflow: hidden;
  }

  /* Connection status banner */
  .chat-conn-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: rgba(255, 255, 255, 0.03);
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    flex-shrink: 0;
  }

  .chat-conn-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .chat-conn-text {
    color: var(--text-secondary);
  }

  .chat-conn-hint {
    margin-left: auto;
    color: var(--text-muted);
  }

  .chat-restart-btn {
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .chat-restart-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }

  /* Attached files bar */
  .chat-attachments {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    padding: 8px 16px;
    border-top: 1px solid rgba(255, 255, 255, 0.06);
    background: rgba(255, 255, 255, 0.02);
    flex-shrink: 0;
  }

  .chat-chip {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 8px 4px 4px;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 8px;
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.75rem;
    max-width: 200px;
  }

  .chat-chip-thumb {
    width: 24px;
    height: 24px;
    border-radius: 4px;
    object-fit: cover;
    flex-shrink: 0;
  }

  .chat-chip-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
    min-width: 0;
  }

  .chat-chip-size {
    color: rgba(255, 255, 255, 0.3);
    font-size: 0.6875rem;
    flex-shrink: 0;
  }

  .chat-chip-remove {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.35);
    cursor: pointer;
    border-radius: 4px;
    flex-shrink: 0;
    transition: color 0.12s, background 0.12s;
  }

  .chat-chip-remove:hover {
    color: rgba(255, 255, 255, 0.8);
    background: rgba(255, 255, 255, 0.1);
  }

  /* Input dock */
  .chat-input-dock {
    border-top: 1px solid rgba(255, 255, 255, 0.06);
    padding: 12px 16px 16px;
    flex-shrink: 0;
  }

  /* Drop overlay */
  .chat-drop-overlay {
    position: absolute;
    inset: 0;
    z-index: 50;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.7);
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
  }

  .chat-drop-inner {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
    padding: 40px 60px;
    border: 2px dashed rgba(255, 255, 255, 0.25);
    border-radius: 16px;
    color: rgba(255, 255, 255, 0.7);
  }

  .chat-drop-text {
    font-size: 1rem;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.85);
  }

  .chat-drop-hint {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.35);
  }
</style>
