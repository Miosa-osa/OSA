<script lang="ts">
  import { slide } from 'svelte/transition';
  import type { ToolCallRef } from '$lib/api/types';
  import DiffView from './DiffView.svelte';

  interface Props {
    tool: ToolCallRef;
    result?: string;
    diff?: string;
    diffStats?: { additions: number; deletions: number };
    isError?: boolean;
    isRunning?: boolean;
    isExpanded: boolean;
    onToggle: () => void;
  }

  let {
    tool,
    result,
    diff,
    diffStats,
    isError = false,
    isRunning = false,
    isExpanded,
    onToggle,
  }: Props = $props();

  const hasDiff = $derived(!!diff);
  const diffFilename = $derived(
    (tool.input?.path as string) || (tool.input?.file_path as string) || 'file'
  );

  const hasResult = $derived(result !== undefined);

  const statusLabel = $derived(
    isRunning ? 'running' : isError ? 'error' : hasResult ? 'done' : 'pending'
  );

  const bodyId = $derived(`tool-body-${tool.id}`);
</script>

<div
  class="tool-call"
  class:tool-call--done={hasResult && !isError}
  class:tool-call--error={isError}
  class:tool-call--running={isRunning}
>
  <button
    class="tool-header"
    onclick={onToggle}
    aria-expanded={isExpanded}
    aria-controls={bodyId}
  >
    <span class="tool-status-dot" aria-hidden="true">
      {#if isRunning}
        <span class="spinner" aria-hidden="true"></span>
      {/if}
    </span>
    <span class="tool-name">{tool.name}</span>
    <span class="tool-status">{statusLabel}</span>
    <span class="tool-chevron" class:rotated={isExpanded} aria-hidden="true">›</span>
  </button>

  {#if isExpanded}
    <div
      id={bodyId}
      class="tool-body"
      transition:slide={{ duration: 180 }}
    >
      <div class="tool-section">
        <p class="tool-section-label">Input</p>
        <pre class="tool-json">{JSON.stringify(tool.input, null, 2)}</pre>
      </div>

      {#if hasDiff}
        <DiffView diff={diff} stats={diffStats} filename={diffFilename} />
      {/if}

      {#if hasResult && !hasDiff}
        <div class="tool-section tool-section--result" class:tool-section--error={isError}>
          <p class="tool-section-label">{isError ? 'Error' : 'Result'}</p>
          <pre class="tool-json">{result}</pre>
        </div>
      {:else if hasResult && hasDiff}
        <details class="tool-raw-result">
          <summary class="tool-section-label">Raw result</summary>
          <pre class="tool-json">{result}</pre>
        </details>
      {/if}
    </div>
  {/if}
</div>

<style>
  .tool-call {
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 8px;
    overflow: hidden;
    background: rgba(255, 255, 255, 0.03);
  }

  .tool-call--done {
    border-color: rgba(255, 255, 255, 0.1);
  }

  .tool-call--error {
    border-color: rgba(239, 68, 68, 0.2);
    background: rgba(239, 68, 68, 0.03);
  }

  .tool-call--running {
    border-color: rgba(234, 179, 8, 0.2);
  }

  .tool-header {
    width: 100%;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    background: none;
    border: none;
    cursor: pointer;
    text-align: left;
    color: rgba(255, 255, 255, 0.6);
    font-size: 0.8125rem;
    transition: background 0.12s;
  }

  .tool-header:hover {
    background: rgba(255, 255, 255, 0.04);
  }

  .tool-status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: rgba(234, 179, 8, 0.7);
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    position: relative;
  }

  .tool-call--done .tool-status-dot {
    background: rgba(74, 222, 128, 0.7);
  }

  .tool-call--error .tool-status-dot {
    background: rgba(239, 68, 68, 0.7);
  }

  .tool-call--running .tool-status-dot {
    background: transparent;
    border: 1.5px solid rgba(234, 179, 8, 0.6);
  }

  /* Spinner for running state */
  .spinner {
    width: 6px;
    height: 6px;
    border: 1.5px solid rgba(234, 179, 8, 0.3);
    border-top-color: rgba(234, 179, 8, 0.9);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    position: absolute;
    inset: -1.5px;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .tool-name {
    font-weight: 500;
    color: rgba(255, 255, 255, 0.8);
    font-family: 'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace;
    font-size: 0.75rem;
  }

  .tool-status {
    font-size: 0.6875rem;
    letter-spacing: 0.05em;
    color: rgba(255, 255, 255, 0.3);
    margin-left: auto;
    text-transform: uppercase;
  }

  .tool-call--error .tool-status {
    color: rgba(239, 68, 68, 0.5);
  }

  .tool-call--running .tool-status {
    color: rgba(234, 179, 8, 0.5);
    animation: pulse-opacity 1.5s ease-in-out infinite;
  }

  @keyframes pulse-opacity {
    0%,
    100% {
      opacity: 0.5;
    }
    50% {
      opacity: 1;
    }
  }

  .tool-chevron {
    font-size: 1rem;
    color: rgba(255, 255, 255, 0.3);
    transition: transform 0.18s ease;
    display: inline-block;
    flex-shrink: 0;
  }

  .tool-chevron.rotated {
    transform: rotate(90deg);
  }

  .tool-body {
    border-top: 1px solid rgba(255, 255, 255, 0.06);
  }

  .tool-section {
    padding: 10px 12px;
  }

  .tool-section--result {
    border-top: 1px solid rgba(255, 255, 255, 0.05);
    background: rgba(74, 222, 128, 0.03);
  }

  .tool-section--error {
    background: rgba(239, 68, 68, 0.04);
    border-top-color: rgba(239, 68, 68, 0.08);
  }

  .tool-section-label {
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.25);
    margin: 0 0 6px;
  }

  .tool-section--error .tool-section-label {
    color: rgba(239, 68, 68, 0.4);
  }

  .tool-json {
    margin: 0;
    font-family: 'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace;
    font-size: 0.75rem;
    line-height: 1.5;
    color: rgba(255, 255, 255, 0.55);
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 240px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .tool-raw-result {
    padding: 8px 12px 4px;
  }

  .tool-raw-result > summary {
    cursor: pointer;
    color: rgba(255, 255, 255, 0.35);
    font-size: 0.6875rem;
    margin-bottom: 4px;
  }
</style>
