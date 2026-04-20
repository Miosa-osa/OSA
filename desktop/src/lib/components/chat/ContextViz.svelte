<script lang="ts">
  interface Props {
    system?: number;
    conversation?: number;
    toolResults?: number;
    total?: number;
  }

  let { system = 0, conversation = 0, toolResults = 0, total = 200000 }: Props = $props();

  const used = $derived(system + conversation + toolResults);
  const available = $derived(total - used);
  const pct = $derived(total > 0 ? Math.round((used / total) * 100) : 0);

  const segments = $derived([
    { label: 'System', tokens: system, color: '#3b82f6', pct: total > 0 ? (system / total * 100) : 0 },
    { label: 'Conversation', tokens: conversation, color: '#06b6d4', pct: total > 0 ? (conversation / total * 100) : 0 },
    { label: 'Tools', tokens: toolResults, color: '#eab308', pct: total > 0 ? (toolResults / total * 100) : 0 },
    { label: 'Available', tokens: available, color: 'rgba(255,255,255,0.08)', pct: total > 0 ? (available / total * 100) : 0 },
  ]);

  function formatTokens(n: number): string {
    if (n < 1000) return `${n}`;
    return `${(n / 1000).toFixed(1)}k`;
  }
</script>

<div
  class="ctx-viz"
  role="meter"
  aria-label="Context window usage: {pct}%"
  aria-valuenow={pct}
  aria-valuemin={0}
  aria-valuemax={100}
>
  <div class="header">
    <span class="label">Context</span>
    <span class="pct" class:warning={pct > 70} class:critical={pct > 90}>{pct}%</span>
  </div>
  <div class="bar">
    {#each segments as seg (seg.label)}
      <div
        class="segment"
        style="width: {Math.max(seg.pct, 0)}%; background: {seg.color}"
        title="{seg.label}: {seg.tokens.toLocaleString()} tokens ({Math.round(seg.pct)}%)"
        role="presentation"
      ></div>
    {/each}
  </div>
  <div class="legend">
    {#each segments as seg (seg.label)}
      <span class="legend-item">
        <span class="dot" style="background: {seg.color}"></span>
        {seg.label}: {formatTokens(seg.tokens)}
      </span>
    {/each}
  </div>
</div>

<style>
  .ctx-viz {
    padding: 8px 12px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  }

  .header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 6px;
  }

  .label {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.4);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .pct {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.6);
    font-variant-numeric: tabular-nums;
  }

  .pct.warning {
    color: #eab308;
  }

  .pct.critical {
    color: #ef4444;
  }

  .bar {
    display: flex;
    height: 6px;
    border-radius: 3px;
    overflow: hidden;
    background: rgba(255, 255, 255, 0.04);
  }

  .segment {
    transition: width 0.3s ease;
  }

  .legend {
    display: flex;
    gap: 12px;
    margin-top: 6px;
    flex-wrap: wrap;
  }

  .legend-item {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.35);
  }

  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }
</style>
