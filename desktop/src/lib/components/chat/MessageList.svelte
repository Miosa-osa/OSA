<script lang="ts">
  import { fly } from 'svelte/transition';
  import MessageBubble from './MessageBubble.svelte';
  import type { Message, ToolCallRef } from '$lib/api/types';

  interface ToolCallState {
    tool: ToolCallRef;
    result?: string;
    isError?: boolean;
    isRunning?: boolean;
    isExpanded: boolean;
  }

  interface Props {
    messages: Message[];
    pendingUserMessage: Message | null;
    isStreaming: boolean;
    /** Synthesised streaming content props */
    streamingText: string;
    streamingThinking: string;
    streamingToolStates: ToolCallState[];
    showTypingDots: boolean;
    /** Orb active state (streaming or voice) */
    orbActive: boolean;
  }

  let {
    messages,
    pendingUserMessage,
    isStreaming,
    streamingText,
    streamingThinking,
    streamingToolStates,
    showTypingDots,
    orbActive,
  }: Props = $props();

  // Viewport ref — scroll management is self-contained here
  let viewportEl = $state<HTMLDivElement | null>(null);
  let isAtBottom = $state(true);

  // Reset to bottom when messages array identity changes (session switch)
  $effect(() => {
    const _len = messages.length;
    void _len;
    if (pendingUserMessage === null && !isStreaming) {
      // session just loaded or cleared — snap to bottom
      isAtBottom = true;
      requestAnimationFrame(() => {
        if (viewportEl) viewportEl.scrollTop = viewportEl.scrollHeight;
      });
    }
  });

  // Auto-scroll when new content arrives and user is near bottom
  $effect(() => {
    const _msgs = messages;
    const _buf = streamingText;
    const _thinking = streamingThinking;
    void _msgs, _buf, _thinking;

    if (isAtBottom && viewportEl) {
      requestAnimationFrame(() => {
        if (viewportEl) viewportEl.scrollTop = viewportEl.scrollHeight;
      });
    }
  });

  function handleScroll() {
    if (!viewportEl) return;
    const { scrollTop, scrollHeight, clientHeight } = viewportEl;
    isAtBottom = scrollHeight - scrollTop - clientHeight < 40;
  }

  function scrollToBottom() {
    isAtBottom = true;
    viewportEl?.scrollTo({ top: viewportEl.scrollHeight, behavior: 'smooth' });
  }

  const hasContent = $derived(
    messages.length > 0 || isStreaming || pendingUserMessage !== null
  );
</script>

<!-- Scrollable message viewport -->
<div
  class="ml-viewport"
  bind:this={viewportEl}
  onscroll={handleScroll}
  aria-label="Chat messages"
  aria-live="polite"
  aria-relevant="additions"
  role="log"
>
  <!-- Empty state -->
  {#if !hasContent}
    <div class="ml-empty" transition:fly={{ y: 16, duration: 300 }}>
      <p class="ml-empty-label">Start a conversation</p>
    </div>
  {/if}

  <div class="ml-list">
    <!-- Persisted messages -->
    {#each messages as message (message.id)}
      <div
        class="ml-row ml-row--{message.role}"
        transition:fly={{ y: 12, duration: 220 }}
      >
        <MessageBubble {message} />
      </div>
    {/each}

    <!-- Optimistic pending user message -->
    {#if pendingUserMessage}
      {@const pending = pendingUserMessage}
      <div
        class="ml-row ml-row--user"
        transition:fly={{ y: 12, duration: 220 }}
      >
        <MessageBubble message={pending} />
      </div>
    {/if}

    <!-- Live assistant streaming bubble -->
    {#if isStreaming}
      <div
        class="ml-row ml-row--assistant"
        transition:fly={{ y: 12, duration: 220 }}
      >
        {#if showTypingDots}
          <div class="ml-typing" aria-label="Agent is typing">
            <span class="ml-dot"></span>
            <span class="ml-dot"></span>
            <span class="ml-dot"></span>
          </div>
        {:else}
          <MessageBubble
            message={{
              id: 'streaming',
              role: 'assistant',
              content: streamingText,
              timestamp: new Date().toISOString(),
            }}
            isStreaming={true}
            streamingToolCalls={streamingToolStates}
            thinkingText={streamingThinking}
            thinkingStreaming={streamingThinking.length > 0 && isStreaming}
          />
        {/if}
      </div>
    {/if}
  </div>
</div>

<!-- Scroll-to-bottom FAB -->
{#if !isAtBottom}
  <button
    class="ml-scroll-btn"
    aria-label="Scroll to latest message"
    onclick={scrollToBottom}
    transition:fly={{ y: 8, duration: 150 }}
  >
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2.5"
      aria-hidden="true"
    >
      <polyline points="6 9 12 15 18 9"></polyline>
    </svg>
  </button>
{/if}

<!-- Orb dock — visible once a conversation has started -->
{#if hasContent}
  <div class="ml-orb-dock">
    <div class="ml-orb-container">
      {#if orbActive}
        <video
          class="ml-orb-active"
          src="/OSLoopingActiveMode.mp4"
          autoplay
          loop
          muted
          playsinline
          aria-hidden="true"
        ></video>
      {:else}
        <img
          src="/OSAIconLogo.png"
          alt=""
          class="ml-orb-idle"
          aria-hidden="true"
        />
      {/if}
    </div>
  </div>
{/if}

<style>
  .ml-viewport {
    position: relative;
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.1) transparent;
  }

  .ml-viewport::-webkit-scrollbar {
    width: 4px;
  }

  .ml-viewport::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 2px;
  }

  .ml-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 20px 16px;
    min-height: 100%;
    justify-content: flex-end;
  }

  .ml-row {
    display: flex;
  }

  .ml-row--user {
    justify-content: flex-end;
  }

  .ml-row--assistant,
  .ml-row--system,
  .ml-row--tool {
    justify-content: flex-start;
  }

  /* Empty state */
  .ml-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    padding: 60px 0;
    color: rgba(255, 255, 255, 0.3);
    flex: 1;
  }

  .ml-empty-label {
    font-size: 0.875rem;
    letter-spacing: 0.04em;
    margin: 0;
  }

  /* Typing indicator */
  .ml-typing {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 14px 16px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 14px;
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
  }

  .ml-dot {
    display: inline-block;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.4);
    animation: ml-bounce 1.2s ease-in-out infinite;
  }

  .ml-dot:nth-child(2) { animation-delay: 0.2s; }
  .ml-dot:nth-child(3) { animation-delay: 0.4s; }

  @keyframes ml-bounce {
    0%, 80%, 100% { transform: translateY(0); }
    40% { transform: translateY(-6px); }
  }

  /* Scroll-to-bottom FAB */
  .ml-scroll-btn {
    position: absolute;
    bottom: 80px;
    right: 16px;
    width: 32px;
    height: 32px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.1);
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    border: 1px solid rgba(255, 255, 255, 0.15);
    color: rgba(255, 255, 255, 0.7);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: background 0.15s, transform 0.15s;
    z-index: 10;
  }

  .ml-scroll-btn:hover {
    background: rgba(255, 255, 255, 0.18);
    transform: translateY(-1px);
  }

  /* Orb dock */
  .ml-orb-dock {
    display: flex;
    justify-content: center;
    padding: 8px 0 4px;
    flex-shrink: 0;
  }

  .ml-orb-container {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    border-radius: 50%;
    clip-path: circle(50%);
    -webkit-clip-path: circle(50%);
    will-change: clip-path;
    transform: translateZ(0);
    width: 36px;
    height: 36px;
  }

  .ml-orb-idle,
  .ml-orb-active {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    pointer-events: none;
    transition: opacity 0.5s ease;
  }

  /* Idle image — scale to push anti-aliased edge outside clip; multiply hides white bg */
  .ml-orb-idle {
    transform: scale(2.1);
    mix-blend-mode: multiply;
  }

  /* Active video — screen makes black bg transparent */
  .ml-orb-active {
    transform: scale(2.1);
    mix-blend-mode: screen;
  }
</style>
