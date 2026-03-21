<script lang="ts">
  import { onMount } from 'svelte';
  import type { Provider, WorkspaceConfig } from '$lib/onboarding/types';
  import { PROVIDERS } from '$lib/onboarding/types';

  interface Props {
    workspace: WorkspaceConfig;
    provider: Provider;
    agentName: string;
    firstTask: string;
    onLaunch: () => Promise<void>;
    onBack: () => void;
  }

  let { workspace, provider, agentName, firstTask, onLaunch, onBack }: Props = $props();

  let launching = $state(false);
  let launched = $state(false);
  let checkVisible = $state(false);

  let providerMeta = $derived(PROVIDERS.find((p) => p.id === provider) ?? null);

  let reducedMotion = false;
  onMount(() => {
    reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  });

  async function handleLaunch() {
    if (launching || launched) return;
    launching = true;
    await onLaunch();
    launching = false;
    launched = true;
    const delay = reducedMotion ? 0 : 80;
    setTimeout(() => { checkVisible = true; }, delay);
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape' && !launched) onBack();
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="sl-root">
  {#if !launched}
    <div class="sl-heading">
      <h1 class="sl-title">Ready to launch</h1>
      <p class="sl-sub">Here's your setup. Launch when you're ready.</p>
    </div>

    <!-- Summary card -->
    <div class="sl-summary" aria-label="Configuration summary">
      <dl class="sl-list">
        <div class="sl-row">
          <dt class="sl-dt">Workspace</dt>
          <dd class="sl-dd">{workspace.name}</dd>
        </div>
        {#if workspace.description}
          <div class="sl-row">
            <dt class="sl-dt">Mission</dt>
            <dd class="sl-dd sl-dd--muted">{workspace.description}</dd>
          </div>
        {/if}
        <div class="sl-row">
          <dt class="sl-dt">Provider</dt>
          <dd class="sl-dd">{providerMeta?.name ?? provider}</dd>
        </div>
        <div class="sl-row">
          <dt class="sl-dt">Agent</dt>
          <dd class="sl-dd">{agentName}</dd>
        </div>
        {#if firstTask}
          <div class="sl-row sl-row--task">
            <dt class="sl-dt">First task</dt>
            <dd class="sl-dd sl-dd--task">{firstTask}</dd>
          </div>
        {/if}
      </dl>
    </div>

    <div class="sl-actions">
      <button class="ob-btn ob-btn--ghost" onclick={onBack} aria-label="Back to first task" disabled={launching}>
        Back
      </button>
      <button
        class="sl-launch-btn"
        onclick={() => void handleLaunch()}
        disabled={launching}
        aria-label="Launch OSA"
      >
        {#if launching}
          <span class="sl-spinner" aria-hidden="true"></span>
          Launching
        {:else}
          <svg class="sl-rocket" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 5.343C15 3.791 13.695 3 12 3c-1.695 0-3 .791-3 2.343v.314C6.68 7.018 5 9.342 5 12v4l-1 1v1h16v-1l-1-1v-4c0-2.658-1.68-4.982-4-5.343v-.314z" />
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 18a2 2 0 104 0" />
          </svg>
          Launch OSA
        {/if}
      </button>
    </div>
  {:else}
    <!-- Success state -->
    <div class="sl-success" aria-live="polite" aria-label="Launch successful">
      <div class="sl-check-wrap" class:sl-check-wrap--visible={checkVisible}>
        <svg class="sl-check-svg" viewBox="0 0 52 52" fill="none" aria-hidden="true">
          <circle class="sl-circle" cx="26" cy="26" r="24" stroke="#22c55e" stroke-width="2" />
          <path
            class="sl-path"
            d="M14 26 L22 34 L38 18"
            stroke="#22c55e"
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </div>
      <p class="sl-done-title" class:sl-done-title--visible={checkVisible}>You're all set.</p>
      <p class="sl-done-sub" class:sl-done-sub--visible={checkVisible}>Taking you to OSA now...</p>
    </div>
  {/if}
</div>

<style>
  .sl-root {
    display: flex;
    flex-direction: column;
    gap: 20px;
    height: 100%;
  }

  .sl-title {
    font-size: 22px;
    font-weight: 800;
    color: #ffffff;
    letter-spacing: -0.03em;
    margin: 0 0 4px;
  }

  .sl-sub {
    font-size: 13px;
    color: #a0a0a0;
    margin: 0;
  }

  .sl-summary {
    flex: 1;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 12px;
    padding: 16px;
  }

  .sl-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin: 0;
    padding: 0;
  }

  .sl-row {
    display: flex;
    align-items: baseline;
    gap: 12px;
  }

  .sl-row--task {
    align-items: flex-start;
    padding-top: 4px;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
    margin-top: 2px;
  }

  .sl-dt {
    font-size: 11px;
    font-weight: 500;
    color: #555555;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    white-space: nowrap;
    min-width: 64px;
  }

  .sl-dd {
    font-size: 13px;
    font-weight: 500;
    color: #ffffff;
    margin: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .sl-dd--muted {
    color: #a0a0a0;
    font-weight: 400;
  }

  .sl-dd--task {
    font-size: 12px;
    font-weight: 400;
    color: #a0a0a0;
    white-space: normal;
    line-height: 1.4;
  }

  .sl-actions {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .sl-launch-btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 10px 24px;
    border-radius: 10px;
    font-size: 13px;
    font-weight: 700;
    cursor: pointer;
    border: none;
    background: #ffffff;
    color: #0a0a0a;
    transition: opacity 0.15s ease, transform 0.1s ease;
    user-select: none;
    letter-spacing: 0.01em;
  }

  .sl-launch-btn:hover:not(:disabled) {
    opacity: 0.9;
  }

  .sl-launch-btn:active:not(:disabled) {
    transform: scale(0.98);
  }

  .sl-launch-btn:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    outline-offset: 2px;
  }

  .sl-launch-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .sl-rocket {
    flex-shrink: 0;
  }

  .sl-spinner {
    width: 13px;
    height: 13px;
    border: 2px solid rgba(0, 0, 0, 0.15);
    border-top-color: #0a0a0a;
    border-radius: 9999px;
    animation: sl-spin 0.6s linear infinite;
  }

  @keyframes sl-spin {
    to { transform: rotate(360deg); }
  }

  /* Success state */
  .sl-success {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    height: 100%;
    gap: 16px;
    text-align: center;
  }

  .sl-check-wrap {
    width: 64px;
    height: 64px;
    opacity: 0;
    transform: scale(0.8);
    transition: opacity 0.3s ease, transform 0.3s ease;
  }

  .sl-check-wrap--visible {
    opacity: 1;
    transform: scale(1);
  }

  .sl-check-svg {
    width: 64px;
    height: 64px;
  }

  .sl-circle {
    stroke-dasharray: 157;
    stroke-dashoffset: 157;
    animation: sl-draw-circle 0.5s ease-out 0.1s forwards;
  }

  .sl-path {
    stroke-dasharray: 36;
    stroke-dashoffset: 36;
    animation: sl-draw-check 0.35s ease-out 0.5s forwards;
  }

  @keyframes sl-draw-circle {
    to { stroke-dashoffset: 0; }
  }

  @keyframes sl-draw-check {
    to { stroke-dashoffset: 0; }
  }

  .sl-done-title {
    font-size: 20px;
    font-weight: 700;
    color: #ffffff;
    letter-spacing: -0.02em;
    margin: 0;
    opacity: 0;
    transform: translateY(6px);
    transition: opacity 0.3s ease 0.7s, transform 0.3s ease 0.7s;
  }

  .sl-done-title--visible {
    opacity: 1;
    transform: translateY(0);
  }

  .sl-done-sub {
    font-size: 13px;
    color: #666666;
    margin: 0;
    opacity: 0;
    transform: translateY(6px);
    transition: opacity 0.3s ease 0.85s, transform 0.3s ease 0.85s;
  }

  .sl-done-sub--visible {
    opacity: 1;
    transform: translateY(0);
  }

  @media (prefers-reduced-motion: reduce) {
    .sl-spinner {
      animation: none;
      opacity: 0.5;
      border-top-color: transparent;
    }

    .sl-circle,
    .sl-path,
    .sl-check-wrap,
    .sl-done-title,
    .sl-done-sub {
      animation: none;
      transition: none;
      opacity: 1;
      transform: none;
      stroke-dashoffset: 0;
    }
  }
</style>
