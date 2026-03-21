import type {
  Signal,
  SignalStats,
  SignalFilters,
  SignalPatterns,
  SignalMode,
  SignalGenre,
  SignalType,
  SignalFormat,
  SignalTier,
} from "$lib/api/types";
import { BASE_URL, API_PREFIX, getToken } from "$lib/api/client";
import { toastStore } from "$lib/stores/toasts.svelte";

// ── Helpers ───────────────────────────────────────────────────────────────────

function buildHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  const token = getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;
  return headers;
}

/** Shape returned by POST /api/v1/classify */
interface ClassifyResponse {
  mode: string;
  genre: string;
  type: string;
  format: string;
  weight: number;
}

// ── Local stat computation ─────────────────────────────────────────────────────

function computeStats(signals: Signal[]): SignalStats {
  const by_mode: Record<string, number> = {};
  const by_channel: Record<string, number> = {};
  const by_type: Record<string, number> = {};
  let weight_sum = 0;
  let haiku = 0;
  let sonnet = 0;
  let opus = 0;

  for (const s of signals) {
    by_mode[s.mode] = (by_mode[s.mode] ?? 0) + 1;
    by_channel[s.channel] = (by_channel[s.channel] ?? 0) + 1;
    by_type[s.type] = (by_type[s.type] ?? 0) + 1;
    weight_sum += s.weight;
    if (s.tier === "haiku") haiku++;
    else if (s.tier === "sonnet") sonnet++;
    else if (s.tier === "opus") opus++;
  }

  return {
    by_mode,
    by_channel,
    by_type,
    weight_distribution: { haiku, sonnet, opus },
    total: signals.length,
    avg_weight: signals.length > 0 ? weight_sum / signals.length : 0,
  };
}

function computePatterns(signals: Signal[]): SignalPatterns {
  // Peak hours: count by hour-of-day
  const hourCounts: number[] = Array(24).fill(0);
  const agentCounts: Record<string, number> = {};
  const dayCounts: Record<string, number> = {};
  let weight_sum = 0;
  let escalation_count = 0;

  for (const s of signals) {
    const d = new Date(s.inserted_at);
    hourCounts[d.getHours()]++;
    agentCounts[s.agent_name] = (agentCounts[s.agent_name] ?? 0) + 1;
    const date = s.inserted_at.slice(0, 10);
    dayCounts[date] = (dayCounts[date] ?? 0) + 1;
    weight_sum += s.weight;
    if (s.weight >= 0.8) escalation_count++;
  }

  const maxCount = Math.max(...hourCounts, 0);
  const peak_hours = hourCounts.reduce<number[]>((acc, c, h) => {
    if (c === maxCount && c > 0) acc.push(h);
    return acc;
  }, []);

  const top_agents = Object.entries(agentCounts)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 5)
    .map(([name, count]) => ({ name, count }));

  const daily_counts = Object.entries(dayCounts)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, count]) => ({ date, count }));

  return {
    peak_hours,
    avg_weight: signals.length > 0 ? weight_sum / signals.length : 0,
    top_agents,
    daily_counts,
    escalation_count,
  };
}

/** Derive a weight-based tier from the classify response weight. */
function tierFromWeight(weight: number): SignalTier {
  if (weight >= 0.8) return "opus";
  if (weight >= 0.5) return "sonnet";
  return "haiku";
}

// ── Store ─────────────────────────────────────────────────────────────────────

const MAX_LIVE_ITEMS = 100;
let _idCounter = 0;

class SignalsStore {
  signals = $state<Signal[]>([]);
  stats = $state<SignalStats | null>(null);
  patterns = $state<SignalPatterns | null>(null);
  filters = $state<SignalFilters>({});
  loading = $state(false);
  error = $state<string | null>(null);
  liveFeed = $state<Signal[]>([]);
  // No SSE endpoint exists — always disconnected
  liveConnected = $state(false);

  /** Recompute stats and patterns from current signal array. */
  #recompute(): void {
    this.stats = computeStats(this.signals);
    this.patterns = computePatterns(this.signals);
  }

  /**
   * Classify a message via POST /api/v1/classify and add the result to the
   * local signals array. Returns the created Signal or null on error.
   */
  async classifyMessage(
    message: string,
    opts?: {
      session_id?: string;
      channel?: string;
      agent_name?: string;
    },
  ): Promise<Signal | null> {
    this.loading = true;
    this.error = null;

    try {
      const res = await fetch(`${BASE_URL}${API_PREFIX}/classify`, {
        method: "POST",
        headers: buildHeaders(),
        body: JSON.stringify({ message }),
      });

      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const data = (await res.json()) as ClassifyResponse;

      const signal: Signal = {
        id: `local-${++_idCounter}-${Date.now()}`,
        session_id: opts?.session_id ?? "local",
        channel: opts?.channel ?? "default",
        mode: (data.mode as SignalMode) ?? "ASSIST",
        genre: (data.genre as SignalGenre) ?? "DIRECT",
        type: (data.type as SignalType) ?? "general",
        format: (data.format as SignalFormat) ?? "message",
        weight: data.weight ?? 0.5,
        tier: tierFromWeight(data.weight ?? 0.5),
        input_preview: message.slice(0, 120),
        agent_name: opts?.agent_name ?? "user",
        confidence: data.weight >= 0.6 ? "high" : "low",
        metadata: {},
        inserted_at: new Date().toISOString(),
      };

      this.signals = [signal, ...this.signals];
      this.liveFeed = [signal, ...this.liveFeed].slice(0, MAX_LIVE_ITEMS);
      this.#recompute();

      return signal;
    } catch (err) {
      const msg =
        err instanceof Error ? err.message : "Failed to classify message.";
      this.error = msg;
      toastStore.add({ type: "error", title: "Classify error", message: msg });
      return null;
    } finally {
      this.loading = false;
    }
  }

  /**
   * Push a pre-built Signal into the store (e.g. from another part of the app).
   * Recomputes stats/patterns automatically.
   */
  addSignal(signal: Signal): void {
    this.signals = [signal, ...this.signals];
    this.liveFeed = [signal, ...this.liveFeed].slice(0, MAX_LIVE_ITEMS);
    this.#recompute();
  }

  /** Apply or replace the active filter set. */
  setFilter(
    key: keyof SignalFilters,
    value: string | number | undefined,
  ): void {
    this.filters = { ...this.filters, [key]: value || undefined };
  }

  clearFilters(): void {
    this.filters = {};
  }

  /**
   * Returns the signals array filtered by the current filter state.
   * Consumers can use this derived view directly.
   */
  get filtered(): Signal[] {
    const f = this.filters;
    return this.signals.filter((s) => {
      if (f.mode && s.mode !== f.mode) return false;
      if (f.type && s.type !== f.type) return false;
      if (f.channel && s.channel !== f.channel) return false;
      if (f.weight_min !== undefined && s.weight < f.weight_min) return false;
      if (f.weight_max !== undefined && s.weight > f.weight_max) return false;
      return true;
    });
  }
}

export const signalsStore = new SignalsStore();
