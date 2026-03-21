<script lang="ts">
  import StatCard   from '$lib/components/usage/StatCard.svelte';
  import UsageChart from '$lib/components/usage/UsageChart.svelte';
  import type { AnalyticsPeriod } from '$lib/stores/usage.svelte';

  interface ModelUsage { model: string; tokens: number; count: number }
  interface DailyEntry { date: string; messages: number; tokens: number }

  interface Props {
    loading: boolean;
    period: AnalyticsPeriod;
    totalMessages: number;
    totalSessions: number;
    totalTokensFormatted: string;
    avgResponseTime: number;
    byModel: ModelUsage[];
    dailyData: DailyEntry[];
  }

  let { loading, period, totalMessages, totalSessions, totalTokensFormatted,
        avgResponseTime, byModel, dailyData }: Props = $props();

  let maxModelTokens = $derived(byModel.length === 0 ? 1 : Math.max(...byModel.map((m) => m.tokens), 1));
  let periodLabel = $derived(period === 'all' ? 'All time' : `Last ${period}`);

  const MODEL_COLORS  = ['rgba(59,130,246,.6)', 'rgba(168,85,247,.6)', 'rgba(34,197,94,.6)', 'rgba(245,158,11,.6)', 'rgba(236,72,153,.6)'];
  const MODEL_BORDERS = ['rgba(59,130,246,.4)', 'rgba(168,85,247,.4)', 'rgba(34,197,94,.4)', 'rgba(245,158,11,.4)', 'rgba(236,72,153,.4)'];

  function formatResponseTime(ms: number): string {
    if (ms === 0) return '—';
    return ms < 1000 ? `${ms}ms` : `${(ms / 1000).toFixed(1)}s`;
  }

  function modelBarPct(tokens: number): number {
    return maxModelTokens === 0 ? 0 : Math.max((tokens / maxModelTokens) * 100, tokens > 0 ? 2 : 0);
  }

  function formatTokens(n: number): string {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${Math.round(n / 1_000)}K`;
    return String(n);
  }
</script>

<!-- Stat cards -->
<section class="ud-stat-grid" aria-label="Summary statistics">
  <StatCard
    label="Total Messages"
    value={loading ? '' : String(totalMessages)}
    subtitle="across all sessions"
    icon="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"
    {loading}
  />
  <StatCard
    label="Sessions"
    value={loading ? '' : String(totalSessions)}
    subtitle="conversation threads"
    icon="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M23 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"
    {loading}
  />
  <StatCard
    label="Tokens"
    value={loading ? '' : totalTokensFormatted}
    subtitle="total processed"
    icon="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"
    {loading}
  />
  <StatCard
    label="Avg Response Time"
    value={loading ? '' : formatResponseTime(avgResponseTime)}
    subtitle="per message"
    icon="M12 22a10 10 0 1 1 0-20 10 10 0 0 1 0 20zm0-14v4l3 3"
    {loading}
  />
</section>

<!-- Charts -->
<section class="ud-charts" aria-label="Usage charts">
  <div class="ud-chart-card glass-panel">
    <header class="ud-chart-header">
      <h2 class="ud-chart-title">Messages</h2>
      <span class="ud-chart-period">{periodLabel}</span>
    </header>
    <div class="ud-chart-body">
      <UsageChart data={dailyData} metric="messages" height={180} />
    </div>
  </div>

  <div class="ud-chart-card glass-panel">
    <header class="ud-chart-header">
      <h2 class="ud-chart-title">Tokens</h2>
      <span class="ud-chart-period">{periodLabel}</span>
    </header>
    <div class="ud-chart-body">
      <UsageChart data={dailyData} metric="tokens" height={180} />
    </div>
  </div>
</section>

<!-- Model breakdown -->
<section class="ud-models glass-panel" aria-label="Model usage breakdown">
  <header class="ud-section-header">
    <h2 class="ud-section-title">Model Usage</h2>
    <span class="ud-section-sub">By token volume</span>
  </header>

  {#if loading}
    <div class="ud-model-list">
      {#each [1, 2, 3] as _}
        <div class="ud-model-row">
          <div class="ud-model-sk-name"></div>
          <div class="ud-model-bar-wrap">
            <div class="ud-model-sk-bar"></div>
          </div>
          <div class="ud-model-sk-stat"></div>
        </div>
      {/each}
    </div>

  {:else if byModel.length === 0}
    <div class="ud-models-empty">
      <p>No model data available for this period</p>
    </div>

  {:else}
    <ol class="ud-model-list" aria-label="Models ranked by token usage">
      {#each byModel as model, i (model.model)}
        <li
          class="ud-model-row"
          aria-label="{model.model}: {formatTokens(model.tokens)} tokens, {model.count} messages"
        >
          <div class="ud-model-info">
            <span class="ud-model-name">{model.model}</span>
            <span class="ud-model-msgs">{model.count} msgs</span>
          </div>
          <div class="ud-model-bar-wrap" aria-hidden="true">
            <div
              class="ud-model-bar"
              style="width: {modelBarPct(model.tokens)}%; background: {MODEL_COLORS[i % MODEL_COLORS.length]}; border-color: {MODEL_BORDERS[i % MODEL_BORDERS.length]}"
            ></div>
          </div>
          <span class="ud-model-tokens">{formatTokens(model.tokens)}</span>
        </li>
      {/each}
    </ol>
  {/if}
</section>

<style>
  .ud-stat-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; }
  @media (max-width: 900px) { .ud-stat-grid { grid-template-columns: repeat(2, 1fr); } }
  @media (max-width: 560px) { .ud-stat-grid { grid-template-columns: 1fr; } }

  .ud-charts { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  @media (max-width: 720px) { .ud-charts { grid-template-columns: 1fr; } }

  .ud-chart-card { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  .ud-chart-header { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
  .ud-chart-title { font-size: 13px; font-weight: 600; color: var(--text-primary); }
  .ud-chart-period { font-size: 11px; color: var(--text-tertiary); }
  .ud-chart-body { flex: 1; min-height: 0; }

  .ud-models { padding: 16px; display: flex; flex-direction: column; gap: 14px; }
  .ud-section-header { display: flex; align-items: baseline; gap: 8px; }
  .ud-section-title { font-size: 13px; font-weight: 600; color: var(--text-primary); }
  .ud-section-sub { font-size: 11px; color: var(--text-tertiary); }
  .ud-model-list { display: flex; flex-direction: column; gap: 10px; list-style: none; }

  .ud-model-row { display: grid; grid-template-columns: 200px 1fr 60px; align-items: center; gap: 12px; }
  @media (max-width: 640px) { .ud-model-row { grid-template-columns: 140px 1fr 48px; } }

  .ud-model-info { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .ud-model-name {
    font-size: 12px; font-weight: 500; color: var(--text-primary);
    font-family: var(--font-mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .ud-model-msgs { font-size: 10px; color: var(--text-tertiary); }
  .ud-model-bar-wrap { height: 8px; background: rgba(255,255,255,.04); border-radius: var(--radius-full); overflow: hidden; }
  .ud-model-bar { height: 100%; border-radius: var(--radius-full); border: 1px solid transparent; transition: width .3s ease; }
  .ud-model-tokens { font-size: 12px; font-weight: 500; color: var(--text-secondary); font-variant-numeric: tabular-nums; text-align: right; }

  .ud-model-sk-name, .ud-model-sk-bar, .ud-model-sk-stat {
    border-radius: var(--radius-sm); background: rgba(255,255,255,.06); animation: ud-shimmer 1.4s ease-in-out infinite;
  }
  .ud-model-sk-name  { height: 12px; width: 140px; }
  .ud-model-sk-bar   { height: 8px; width: 100%; border-radius: var(--radius-full); animation-delay: .1s; }
  .ud-model-sk-stat  { height: 12px; width: 40px; margin-left: auto; animation-delay: .2s; }
  .ud-models-empty { padding: 24px 0; text-align: center; font-size: 13px; color: var(--text-tertiary); }

  @keyframes ud-shimmer { 0%, 100% { opacity: .5; } 50% { opacity: 1; } }

  @media (prefers-reduced-motion: reduce) {
    .ud-model-sk-name, .ud-model-sk-bar, .ud-model-sk-stat { animation: none; }
    .ud-model-bar { transition: none; }
  }
</style>
