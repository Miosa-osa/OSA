<script lang="ts">
  import { slide } from 'svelte/transition';

  interface Props {
    diff: string;
    stats?: { additions: number; deletions: number };
    filename?: string;
  }

  let { diff, stats, filename = 'file' }: Props = $props();

  let expanded = $state(false);

  const lines = $derived(diff.split('\n'));

  function lineClass(line: string): string {
    if (line.startsWith('+++') || line.startsWith('---')) return 'meta';
    if (line.startsWith('+')) return 'addition';
    if (line.startsWith('-')) return 'deletion';
    if (line.startsWith('@@')) return 'hunk';
    return 'context';
  }
</script>

<div class="diff-container">
  <button
    class="diff-header"
    onclick={() => (expanded = !expanded)}
    aria-expanded={expanded}
    aria-label="Toggle diff for {filename}"
  >
    <span class="diff-filename">{filename}</span>
    {#if stats}
      <span class="diff-stats">
        <span class="stat-add">+{stats.additions}</span>
        <span class="stat-del">-{stats.deletions}</span>
      </span>
    {/if}
    <span class="diff-chevron" class:diff-chevron--open={expanded} aria-hidden="true">›</span>
  </button>

  {#if expanded}
    <div class="diff-body" transition:slide={{ duration: 180 }}>
      {#each lines as line, i}
        {#if line.trim() !== ''}
          <div class="diff-line diff-line--{lineClass(line)}">
            <span class="line-num">{i + 1}</span>
            <span class="line-content">{line}</span>
          </div>
        {/if}
      {/each}
    </div>
  {/if}
</div>

<style>
  .diff-container {
    margin: 4px 0;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 6px;
    overflow: hidden;
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.75rem;
  }

  .diff-header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 10px;
    background: rgba(255, 255, 255, 0.03);
    cursor: pointer;
    width: 100%;
    border: none;
    color: inherit;
    text-align: left;
  }

  .diff-header:hover {
    background: rgba(255, 255, 255, 0.05);
  }

  .diff-filename {
    flex: 1;
    color: rgba(255, 255, 255, 0.7);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .diff-stats {
    display: flex;
    gap: 6px;
    flex-shrink: 0;
  }

  .stat-add {
    color: #4ade80;
  }

  .stat-del {
    color: #f87171;
  }

  .diff-chevron {
    color: rgba(255, 255, 255, 0.3);
    transition: transform 0.15s;
    flex-shrink: 0;
  }

  .diff-chevron--open {
    transform: rotate(90deg);
  }

  .diff-body {
    padding: 4px 0;
    background: rgba(0, 0, 0, 0.3);
    overflow-x: auto;
  }

  .diff-line {
    display: flex;
    padding: 1px 8px;
    white-space: pre;
    line-height: 1.5;
  }

  .line-num {
    width: 32px;
    text-align: right;
    color: rgba(255, 255, 255, 0.15);
    padding-right: 8px;
    flex-shrink: 0;
    user-select: none;
  }

  .line-content {
    flex: 1;
  }

  .diff-line--addition {
    background: rgba(74, 222, 128, 0.08);
    color: #4ade80;
  }

  .diff-line--deletion {
    background: rgba(248, 113, 113, 0.08);
    color: #f87171;
  }

  .diff-line--hunk {
    color: #60a5fa;
    background: rgba(96, 165, 250, 0.05);
  }

  .diff-line--meta {
    color: rgba(255, 255, 255, 0.25);
  }

  .diff-line--context {
    color: rgba(255, 255, 255, 0.4);
  }
</style>
