// src/lib/stores/dashboard.svelte.ts
// Dashboard state with periodic refresh.

import { BASE_URL, API_PREFIX, getToken } from "$api/client";
import type {
  DashboardApiResponse,
  DashboardData,
  DashboardKpis,
  DashboardAgent,
  DashboardActivity,
  DashboardSystemHealth,
} from "$api/types";
import { toastStore } from "$lib/stores/toasts.svelte";

const EMPTY_KPIS: DashboardKpis = {
  active_sessions: 0,
  agents_online: 0,
  agents_total: 0,
  signals_today: 0,
  tasks_completed: 0,
  tasks_pending: 0,
  tokens_used_today: 0,
  uptime_seconds: 0,
};

const EMPTY_HEALTH: DashboardSystemHealth = {
  backend: "ok",
  provider: null,
  provider_status: "disconnected",
  memory_mb: 0,
};

/**
 * Normalize the flat GET /api/v1/dashboard response into DashboardData.
 * The store still uses the richer DashboardData shape internally so that
 * all existing consumers of kpis / systemHealth / activeAgents continue
 * to work without changes.
 */
function normalize(raw: DashboardApiResponse): DashboardData {
  const kpis: DashboardKpis = {
    active_sessions: raw.active_sessions,
    agents_online: raw.active_agents,
    agents_total: raw.active_agents,
    signals_today: 0,
    tasks_completed: 0,
    tasks_pending: raw.scheduled_tasks,
    tokens_used_today: 0,
    uptime_seconds: raw.uptime_seconds,
  };

  const systemHealth: DashboardSystemHealth = {
    backend: raw.status,
    provider: raw.provider,
    provider_status: raw.provider ? "connected" : "disconnected",
    memory_mb: raw.memory_mb,
  };

  return {
    kpis,
    active_agents: [] as DashboardAgent[],
    recent_activity: raw.recent_activity ?? [],
    system_health: systemHealth,
  };
}

async function fetchDashboard(): Promise<DashboardData> {
  const headers: Record<string, string> = { Accept: "application/json" };
  const token = getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await globalThis.fetch(`${BASE_URL}${API_PREFIX}/dashboard`, {
    headers,
  });

  if (!res.ok) throw new Error(`HTTP ${res.status}`);

  const json = (await res.json()) as DashboardApiResponse | DashboardData;

  // Handle both the new flat shape and the legacy nested shape gracefully.
  if ("kpis" in json) {
    // Legacy backend returning nested DashboardData directly
    return json as DashboardData;
  }
  return normalize(json as DashboardApiResponse);
}

class DashboardStore {
  kpis = $state<DashboardKpis>(EMPTY_KPIS);
  activeAgents = $state<DashboardAgent[]>([]);
  recentActivity = $state<DashboardActivity[]>([]);
  systemHealth = $state<DashboardSystemHealth>(EMPTY_HEALTH);
  loading = $state(true);
  error = $state<string | null>(null);
  // True when the error is a network-level failure (backend unreachable), false
  // when the backend responded but returned an unexpected status code.
  isOffline = $state(false);
  lastUpdated = $state<Date | null>(null);

  #interval: ReturnType<typeof setInterval> | null = null;

  async load(): Promise<void> {
    try {
      const data = await fetchDashboard();
      this.kpis = data.kpis;
      this.activeAgents = data.active_agents;
      this.recentActivity = data.recent_activity;
      this.systemHealth = data.system_health;
      this.error = null;
      this.isOffline = false;
    } catch (e) {
      const err = e as Error;
      // TypeError is thrown by fetch() when the network is unreachable.
      // An "HTTP NNN" message means the server was reachable but returned an error.
      const wasOffline = this.isOffline;
      this.isOffline =
        err.name === "TypeError" || err.message === "Failed to fetch";
      this.error = err.message;
      if (this.isOffline && !wasOffline) {
        toastStore.warning("Backend offline — some features unavailable");
      } else if (!this.isOffline) {
        toastStore.error("Failed to load dashboard");
      }
    } finally {
      this.loading = false;
      this.lastUpdated = new Date();
    }
  }

  startAutoRefresh(intervalMs = 30_000): () => void {
    // Clear any pre-existing interval before starting a new one (guards against
    // double-mount in SPA navigation when the singleton is reused).
    this.stopAutoRefresh();
    // Reset loading so the skeleton renders on every re-visit.
    this.loading = true;
    this.load();
    this.#interval = setInterval(() => this.load(), intervalMs);
    return () => this.stopAutoRefresh();
  }

  stopAutoRefresh(): void {
    if (this.#interval !== null) {
      clearInterval(this.#interval);
      this.#interval = null;
    }
  }
}

export const dashboardStore = new DashboardStore();
