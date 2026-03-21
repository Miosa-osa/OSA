<script lang="ts">
  import { fly, fade } from 'svelte/transition';
  import { marked } from 'marked';
  import DOMPurify from 'dompurify';
  import { planStore } from '$lib/stores/plan.svelte';

  // ── Local state ─────────────────────────────────────────────────────────────

  let editMode = $state(false);
  let editText = $state('');

  // Step count badge: count markdown headings as plan steps
  const stepCount = $derived(() => {
    const text = planStore.pendingPlan?.text ?? '';
    const matches = text.match(/^#{1,3}\s/gm);
    return matches ? matches.length : 0;
  });

  const renderedPlan = $derived(() => {
    const text = planStore.pendingPlan?.text ?? '';
    if (!text) return '';
    try {
      const raw = marked.parse(text, { async: false }) as string;
      return DOMPurify.sanitize(raw);
    } catch {
      return DOMPurify.sanitize(text);
    }
  });

  // ── Actions ─────────────────────────────────────────────────────────────────

  function openEdit() {
    editText = planStore.pendingPlan?.text ?? '';
    editMode = true;
  }

  function cancelEdit() {
    editMode = false;
  }

  function handleApprove() {
    editMode = false;
    planStore.approve();
  }

  function handleReject() {
    editMode = false;
    planStore.reject();
  }

  function handleSubmitEdit() {
    if (!editText.trim()) return;
    planStore.submitEdit(editText);
    editMode = false;
  }

  // ── Keyboard handler ────────────────────────────────────────────────────────

  function onKeydown(e: KeyboardEvent) {
    if (!planStore.isVisible) return;

    // Don't intercept when typing in the textarea
    if (e.target instanceof HTMLTextAreaElement) return;

    if (e.key === 'Enter' || e.key === 'a' || e.key === 'A') {
      e.preventDefault();
      handleApprove();
    } else if (e.key === 'r' || e.key === 'R') {
      e.preventDefault();
      handleReject();
    } else if (e.key === 'e' || e.key === 'E') {
      e.preventDefault();
      openEdit();
    } else if (e.key === 'Escape') {
      if (editMode) {
        cancelEdit();
      } else {
        handleReject();
      }
    }
  }
</script>

<svelte:window onkeydown={onKeydown} />

{#if planStore.isVisible}
  <!-- Backdrop -->
  <div
    class="backdrop"
    transition:fade={{ duration: 180 }}
    onclick={handleReject}
    aria-hidden="true"
  ></div>

  <!-- Panel -->
  <div
    class="plan-panel"
    transition:fly={{ y: 100, duration: 250, opacity: 1 }}
    role="dialog"
    aria-modal="true"
    aria-label="Plan Review"
  >
    <!-- Header -->
    <header class="plan-header">
      <div class="plan-header-left">
        <span class="plan-icon" aria-hidden="true">◈</span>
        <h2 class="plan-title">Plan Review</h2>
        {#if stepCount() > 0}
          <span class="plan-badge" aria-label="{stepCount()} steps">
            {stepCount()} steps
          </span>
        {/if}
      </div>
      <button
        class="plan-close"
        onclick={handleReject}
        aria-label="Close and reject plan"
      >
        ✕
      </button>
    </header>

    <div class="plan-divider"></div>

    <!-- Content area -->
    <div class="plan-content selectable">
      {#if editMode}
        <textarea
          class="plan-editor glass-input"
          bind:value={editText}
          rows={16}
          aria-label="Edit plan"
          spellcheck="false"
        ></textarea>
      {:else}
        <div class="plan-markdown">
          {@html renderedPlan()}
        </div>
      {/if}
    </div>

    <div class="plan-divider"></div>

    <!-- Footer actions -->
    <footer class="plan-footer">
      {#if editMode}
        <div class="plan-actions">
          <button
            class="plan-btn plan-btn--ghost"
            onclick={cancelEdit}
            aria-label="Cancel edit"
          >
            Cancel
          </button>
          <button
            class="plan-btn plan-btn--primary"
            onclick={handleSubmitEdit}
            aria-label="Submit edited plan"
            disabled={!editText.trim()}
          >
            Submit Edit
          </button>
        </div>
      {:else}
        <div class="plan-actions">
          <div class="plan-hints" aria-hidden="true">
            <kbd>A</kbd> approve &nbsp; <kbd>R</kbd> reject &nbsp; <kbd>E</kbd> edit
          </div>
          <div class="plan-action-btns">
            <button
              class="plan-btn plan-btn--ghost"
              onclick={handleReject}
              aria-label="Reject plan (R)"
            >
              Reject
            </button>
            <button
              class="plan-btn plan-btn--ghost"
              onclick={openEdit}
              aria-label="Edit plan (E)"
            >
              Edit
            </button>
            <button
              class="plan-btn plan-btn--primary"
              onclick={handleApprove}
              aria-label="Approve plan (Enter or A)"
            >
              Approve
            </button>
          </div>
        </div>
      {/if}
    </footer>
  </div>
{/if}

<style>
  /* ── Backdrop ── */

  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.55);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    z-index: var(--z-modal-backdrop);
    cursor: default;
  }

  /* ── Panel ── */

  .plan-panel {
    position: fixed;
    bottom: 0;
    left: 0;
    right: 0;
    height: 60dvh;
    min-height: 360px;
    max-height: 760px;
    z-index: var(--z-modal);

    display: flex;
    flex-direction: column;

    /* Glassmorphic — frosted style from app.css tokens */
    background: rgba(18, 18, 20, 0.92);
    backdrop-filter: blur(40px) saturate(1.4);
    -webkit-backdrop-filter: blur(40px) saturate(1.4);
    border-top: 1px solid rgba(255, 255, 255, 0.12);
    border-left: 1px solid rgba(255, 255, 255, 0.06);
    border-right: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-xl) var(--radius-xl) 0 0;
    box-shadow:
      0 -8px 40px rgba(0, 0, 0, 0.4),
      0 -2px 8px rgba(0, 0, 0, 0.2),
      inset 0 1px 0 rgba(255, 255, 255, 0.08);
  }

  /* ── Header ── */

  .plan-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 16px 20px 14px;
    flex-shrink: 0;
  }

  .plan-header-left {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .plan-icon {
    font-size: 1rem;
    color: rgba(255, 255, 255, 0.4);
    flex-shrink: 0;
  }

  .plan-title {
    font-size: 0.9375rem;
    font-weight: 600;
    letter-spacing: 0.01em;
    color: rgba(255, 255, 255, 0.9);
    margin: 0;
  }

  .plan-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 9px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: var(--radius-full);
    font-size: 0.6875rem;
    font-weight: 500;
    letter-spacing: 0.04em;
    color: rgba(255, 255, 255, 0.5);
    text-transform: uppercase;
  }

  .plan-close {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-sm);
    color: rgba(255, 255, 255, 0.4);
    font-size: 0.75rem;
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }

  .plan-close:hover {
    background: rgba(255, 255, 255, 0.1);
    color: rgba(255, 255, 255, 0.8);
  }

  /* ── Divider ── */

  .plan-divider {
    height: 1px;
    background: linear-gradient(
      90deg,
      transparent,
      rgba(255, 255, 255, 0.08),
      transparent
    );
    flex-shrink: 0;
  }

  /* ── Scrollable content ── */

  .plan-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.1) transparent;
  }

  .plan-markdown {
    font-size: 0.9375rem;
    line-height: 1.7;
    color: rgba(255, 255, 255, 0.82);
  }

  /* Markdown resets inside plan */
  .plan-markdown :global(h1),
  .plan-markdown :global(h2),
  .plan-markdown :global(h3) {
    color: rgba(255, 255, 255, 0.92);
    font-weight: 600;
    margin: 1em 0 0.4em;
    line-height: 1.3;
  }

  .plan-markdown :global(h1) { font-size: 1.1em; }
  .plan-markdown :global(h2) { font-size: 1em; }
  .plan-markdown :global(h3) { font-size: 0.9375em; }

  .plan-markdown :global(p) {
    margin: 0 0 0.65em;
  }

  .plan-markdown :global(p:last-child) {
    margin-bottom: 0;
  }

  .plan-markdown :global(ul),
  .plan-markdown :global(ol) {
    margin: 0.4em 0 0.65em;
    padding-left: 1.5em;
  }

  .plan-markdown :global(li) {
    margin-bottom: 0.3em;
    color: rgba(255, 255, 255, 0.75);
  }

  .plan-markdown :global(code) {
    font-family: var(--font-mono);
    font-size: 0.84em;
    background: rgba(255, 255, 255, 0.07);
    padding: 1px 5px;
    border-radius: 4px;
    border: 1px solid rgba(255, 255, 255, 0.07);
    color: rgba(255, 255, 255, 0.85);
  }

  .plan-markdown :global(pre) {
    margin: 0.5em 0;
    padding: 12px 14px;
    background: rgba(0, 0, 0, 0.4);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 8px;
    overflow-x: auto;
  }

  .plan-markdown :global(pre code) {
    background: transparent;
    border: none;
    padding: 0;
    font-size: 0.8125rem;
    line-height: 1.6;
  }

  .plan-markdown :global(blockquote) {
    margin: 0.5em 0;
    padding: 6px 12px;
    border-left: 3px solid rgba(255, 255, 255, 0.15);
    color: rgba(255, 255, 255, 0.5);
    font-style: italic;
  }

  .plan-markdown :global(hr) {
    border: none;
    border-top: 1px solid rgba(255, 255, 255, 0.08);
    margin: 0.9em 0;
  }

  /* ── Edit textarea ── */

  .plan-editor {
    width: 100%;
    resize: none;
    font-family: var(--font-mono);
    font-size: 0.8375rem;
    line-height: 1.65;
    min-height: 200px;
    height: 100%;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-md);
    padding: 14px 16px;
    color: rgba(255, 255, 255, 0.88);
    outline: none;
    transition: border-color 0.15s;
  }

  .plan-editor:focus {
    border-color: rgba(255, 255, 255, 0.22);
    box-shadow: 0 0 0 3px rgba(255, 255, 255, 0.04);
  }

  /* ── Footer ── */

  .plan-footer {
    padding: 14px 20px;
    flex-shrink: 0;
  }

  .plan-actions {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }

  .plan-action-btns {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-left: auto;
  }

  .plan-hints {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.22);
    letter-spacing: 0.02em;
  }

  .plan-hints kbd {
    display: inline-block;
    padding: 0 4px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 3px;
    font-family: var(--font-mono);
    font-size: 0.625rem;
    color: rgba(255, 255, 255, 0.35);
  }

  /* ── Buttons ── */

  .plan-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 7px 16px;
    border-radius: var(--radius-sm);
    font-size: 0.875rem;
    font-weight: 500;
    transition: background 0.15s, border-color 0.15s, color 0.15s, opacity 0.15s;
    cursor: pointer;
  }

  .plan-btn:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }

  /* Ghost button */
  .plan-btn--ghost {
    background: transparent;
    border: 1px solid rgba(255, 255, 255, 0.12);
    color: rgba(255, 255, 255, 0.6);
  }

  .plan-btn--ghost:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.06);
    border-color: rgba(255, 255, 255, 0.2);
    color: rgba(255, 255, 255, 0.88);
  }

  /* Primary — white */
  .plan-btn--primary {
    background: rgba(255, 255, 255, 0.94);
    border: 1px solid rgba(255, 255, 255, 0.94);
    color: #0a0a0a;
    font-weight: 600;
  }

  .plan-btn--primary:hover:not(:disabled) {
    background: #ffffff;
    border-color: #ffffff;
  }
</style>
