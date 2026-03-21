// src/lib/stores/usage.svelte.ts
// Usage & Analytics store — Svelte 5 class with $state fields.
// Fetches system analytics from GET /api/v1/analytics.

import {
  BASE_URL,
  API_PREFIX,
  getToken,
  costs,
  budgets,
} from "$lib/api/client";
import type {
  AgentBudget,
  CostByAgent,
  CostByModel,
  CostSummary,
} from "$lib/api/types";

// ── Types ──────────────────────────────────────────────────────────────────────

export type AnalyticsPeriod = "7d" | "30d" | "all";

export interface DailyUsage {
  date: string; // ISO date string "YYYY-MM-DD"
  messages: number;
  tokens: number;
}

export interface ModelUsage {
  model: string;
  count: number;
  tokens: number;
}

export interface UsageStats {
  totalMessages: number;
  totalSessions: number;
  totalTokens: number;
  avgResponseTime: number; // milliseconds
  dailyUsage: DailyUsage[];
  modelUsage: ModelUsage[];
}

// ── Backend response shape ─────────────────────────────────────────────────────
// The Elixir backend may return snake_case keys — map on ingestion.

interface AnalyticsApiResponse {
  total_messages?: number;
  totalMessages?: number;
  total_sessions?: number;
  totalSessions?: number;
  total_tokens?: number;
  totalTokens?: number;
  avg_response_time?: number;
  avgResponseTime?: number;
  daily_usage?: RawDailyEntry[];
  dailyUsage?: RawDailyEntry[];
  model_usage?: RawModelEntry[];
  modelUsage?: RawModelEntry[];
}

interface RawDailyEntry {
  date: string;
  messages?: number;
  tokens?: number;
}

interface RawModelEntry {
  model: string;
  count?: number;
  tokens?: number;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Format a token count to a compact human-readable string.
 * 0        → "0"
 * 1–999    → "850"
 * 1K–999K  → "850K"
 * 1M+      → "4.2M"
 */
function formatTokens(count: number): string {
  if (!Number.isFinite(count) || count <= 0) return "0";
  if (count < 1_000) return String(Math.round(count));
  if (count < 1_000_000) {
    const k = count / 1_000;
    return k % 1 === 0 ? `${k}K` : `${k.toFixed(1)}K`;
  }
  const m = count / 1_000_000;
  return m % 1 === 0 ? `${m}M` : `${m.toFixed(1)}M`;
}

/**
 * Return the ISO date string for N days ago from today (UTC).
 */
function daysAgoISO(days: number): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().slice(0, 10);
}

/**
 * Map the raw API response to UsageStats, tolerating snake_case or camelCase.
 */
function mapApiResponse(raw: AnalyticsApiResponse): UsageStats {
  const dailyRaw = raw.daily_usage ?? raw.dailyUsage ?? [];
  const modelRaw = raw.model_usage ?? raw.modelUsage ?? [];

  return {
    totalMessages: raw.total_messages ?? raw.totalMessages ?? 0,
    totalSessions: raw.total_sessions ?? raw.totalSessions ?? 0,
    totalTokens: raw.total_tokens ?? raw.totalTokens ?? 0,
    avgResponseTime: raw.avg_response_time ?? raw.avgResponseTime ?? 0,
    dailyUsage: dailyRaw.map((entry) => ({
      date: entry.date,
      messages: entry.messages ?? 0,
      tokens: entry.tokens ?? 0,
    })),
    modelUsage: modelRaw.map((entry) => ({
      model: entry.model,
      count: entry.count ?? 0,
      tokens: entry.tokens ?? 0,
    })),
  };
}

// ── UsageStore ────────────────────────────────────────────────────────────────

class UsageStore {
  stats = $state<UsageStats | null>(null);
  loading = $state(false);
  error = $state<string | null>(null);
  period = $state<AnalyticsPeriod>("30d");
  summary = $state<CostSummary | null>(null);
  agentBudgets = $state<AgentBudget[]>([]);
  costByModel = $state<CostByModel[]>([]);
  costByAgent = $state<CostByAgent[]>([]);
  budgetLoading = $state(false);
  dailyPct = $derived((): number => {
    if (!this.summary || this.summary.daily_limit_cents === 0) return 0;
    return (
      (this.summary.daily_spent_cents / this.summary.daily_limit_cents) * 100
    );
  });
  monthlyPct = $derived((): number => {
    if (!this.summary || this.summary.monthly_limit_cents === 0) return 0;
    return (
      (this.summary.monthly_spent_cents / this.summary.monthly_limit_cents) *
      100
    );
  });
  pausedAgents = $derived((): string[] => {
    return this.agentBudgets
      .filter((a) => a.status === "paused_budget")
      .map((a) => a.agent_name);
  });

  // ── Derived ──────────────────────────────────────────────────────────────────

  /**
   * dailyUsage entries filtered to the selected period.
   * "all" returns all entries unfiltered.
   */
  filteredDailyUsage = $derived((): DailyUsage[] => {
    if (!this.stats) return [];
    if (this.period === "all") return this.stats.dailyUsage;

    const days = this.period === "7d" ? 7 : 30;
    const cutoff = daysAgoISO(days);
    return this.stats.dailyUsage.filter((entry) => entry.date >= cutoff);
  });

  /**
   * The day with the highest message count within the current period.
   * Returns null when there is no data.
   */
  peakDay = $derived((): DailyUsage | null => {
    const entries = this.filteredDailyUsage();
    if (entries.length === 0) return null;
    return entries.reduce((best, entry) =>
      entry.messages > best.messages ? entry : best,
    );
  });

  /**
   * Total tokens formatted as a compact string ("0", "850K", "4.2M").
   */
  totalTokensFormatted = $derived((): string => {
    if (!this.stats) return "0";
    return formatTokens(this.stats.totalTokens);
  });

  /**
   * Average messages per day across the filtered period.
   * Returns 0 when there are no entries to avoid division by zero.
   */
  avgMessagesPerDay = $derived((): number => {
    const entries = this.filteredDailyUsage();
    if (entries.length === 0) return 0;
    const total = entries.reduce((s, e) => s + e.messages, 0);
    return Math.round((total / entries.length) * 10) / 10;
  });

  // ── Actions ──────────────────────────────────────────────────────────────────

  /**
   * Fetch analytics from the backend.
   * The analytics endpoint is not yet in the shared API client, so we make a
   * raw fetch using the same base URL and auth token.
   */
  async fetchUsage(): Promise<void> {
    this.loading = true;
    this.error = null;

    try {
      const url = `${BASE_URL}${API_PREFIX}/analytics`;
      const headers: Record<string, string> = {
        "Content-Type": "application/json",
        Accept: "application/json",
      };

      const token = getToken();
      if (token) {
        headers["Authorization"] = `Bearer ${token}`;
      }

      const response = await fetch(url, { headers });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: /api/v1/analytics`);
      }

      const raw = (await response.json()) as AnalyticsApiResponse;
      this.stats = mapApiResponse(raw);
    } catch {
      this.stats = null;
      this.error = "Backend offline";
    } finally {
      this.loading = false;
    }
  }

  /**
   * Change the active period filter. Does not re-fetch; filters existing stats.
   */
  setPeriod(p: AnalyticsPeriod): void {
    this.period = p;
  }

  async fetchBudgets(): Promise<void> {
    this.budgetLoading = true;
    try {
      const [s, b, m, a] = await Promise.all([
        costs.summary(),
        budgets.list(),
        costs.byModel(),
        costs.byAgent(),
      ]);
      this.summary = s;
      this.agentBudgets = b.budgets ?? [];
      this.costByModel = m.models ?? [];
      this.costByAgent = a.agents ?? [];
    } catch {
      // Fallback: leave existing state or set defaults
      if (!this.summary) {
        this.summary = {
          daily_spent_cents: 0,
          monthly_spent_cents: 0,
          daily_limit_cents: 25000,
          monthly_limit_cents: 250000,
          daily_events: 0,
          monthly_events: 0,
        };
      }
    } finally {
      this.budgetLoading = false;
    }
  }

  async updateBudget(
    agentName: string,
    dailyCents: number,
    monthlyCents: number,
  ): Promise<void> {
    await budgets.update(agentName, dailyCents, monthlyCents);
    await this.fetchBudgets();
  }

  async resetBudget(agentName: string): Promise<void> {
    await budgets.reset(agentName);
    await this.fetchBudgets();
  }
}

// ── Singleton Export ───────────────────────────────────────────────────────────

export const usageStore = new UsageStore();
