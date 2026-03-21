// src/lib/api/client.ts
// HTTP API client for the OSA backend at localhost:9089/api/v1

import { load as loadStore } from "@tauri-apps/plugin-store";
import type {
  Agent,
  AgentBudget,
  AgentHierarchyResponse,
  AgentsListResponse,
  ConfigDiff,
  ConfigRevision,
  CostByAgent,
  CostByModel,
  CostEvent,
  CostSummary,
  CreateGoalPayload,
  CreateProjectPayload,
  CreateSessionRequest,
  CreateSessionResponse,
  Goal,
  GoalTreeNode,
  HealthResponse,
  HierarchyNode,
  HierarchyUpdateRequest,
  Message,
  Model,
  OnboardingStatus,
  OrchestrateRequest,
  OrchestrateResponse,
  Project,
  ProjectTask,
  Provider,
  QueuedRequest,
  SendMessageRequest,
  SendMessageResponse,
  Session,
  Settings,
  Skill,
  SkillCategoryCount,
  SkillDetail,
  SkillSearchResult,
} from "./types";

// ── Configuration ─────────────────────────────────────────────────────────────

export const BASE_URL = "http://127.0.0.1:9089";
export const API_PREFIX = "/api/v1";

// ── Token Store ───────────────────────────────────────────────────────────────

let _token: string | null = null;
let _refreshPromise: Promise<string | null> | null = null;
let _refreshTimerId: ReturnType<typeof setInterval> | null = null;

export function getToken(): string | null {
  return _token;
}

export function setToken(token: string | null): void {
  _token = token;
}

// ── Auth Initialization ───────────────────────────────────────────────────────

/**
 * Initializes authentication by:
 * 1. Reading any previously stored token from the Tauri store
 * 2. If absent, logging in with an auto-generated user_id to obtain one
 * 3. Persisting the token and scheduling periodic refreshes
 *
 * Call once from the root layout onMount.
 */
export async function initializeAuth(): Promise<void> {
  // Step 1: Try to recover a previously stored token
  try {
    const store = await loadStore("store.json", {
      autoSave: true,
      defaults: {},
    });
    const stored = await store.get<string>("authToken");
    if (stored) {
      _token = stored;
    }
  } catch {
    // Tauri store unavailable (e.g. running in browser dev mode) — proceed to login
  }

  // Step 2: If no token, login to obtain one
  if (!_token) {
    try {
      const userId = crypto.randomUUID();
      const response = await fetch(`${BASE_URL}${API_PREFIX}/auth/login`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: userId }),
      });

      if (response.ok) {
        const data = (await response.json()) as { token: string };
        _token = data.token;

        // Persist for future sessions
        try {
          const store = await loadStore("store.json", {
            autoSave: true,
            defaults: {},
          });
          await store.set("authToken", _token);
          await store.save();
        } catch {
          // Non-fatal — token is in-memory for this session
        }
      }
    } catch {
      // Backend may not yet be ready — requests will proceed unauthenticated
      // and will auto-refresh on first 401
    }
  }

  // Step 3: Schedule token refresh every 10 minutes
  if (_refreshTimerId !== null) {
    clearInterval(_refreshTimerId);
  }
  _refreshTimerId = setInterval(
    () => {
      void refreshToken();
    },
    10 * 60 * 1000,
  );
}

// ── Typed Error ───────────────────────────────────────────────────────────────

export class ApiError extends Error {
  readonly status: number;
  readonly code: string | undefined;
  readonly body: unknown;

  constructor(status: number, message: string, body?: unknown) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code =
      typeof body === "object" && body !== null && "code" in body
        ? String((body as Record<string, unknown>).code)
        : undefined;
    this.body = body;
  }
}

// ── Retry with Backoff ──────────────────────────────────────────────────────

interface RetryConfig {
  maxRetries: number;
  backoffMs: number;
  maxBackoff: number;
}

// ── Retry with Backoff ──────────────────────────────────────────────────────

interface RetryConfig {
  maxRetries: number;
  backoffMs: number;
  maxBackoff: number;
}
const DEFAULT_RETRY: RetryConfig = {
  maxRetries: 3,
  backoffMs: 1000,
  maxBackoff: 30000,
};

async function withRetry<T>(
  fn: () => Promise<T>,
  config = DEFAULT_RETRY,
): Promise<T> {
  let lastError: Error = new Error("No attempts made");
  for (let attempt = 0; attempt < config.maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error as Error;
      if (error instanceof ApiError && error.status < 500) throw error;
      const delay = Math.min(
        config.backoffMs * 2 ** attempt,
        config.maxBackoff,
      );
      await new Promise((r) => setTimeout(r, delay));
    }
  }
  throw lastError;
}

// ── Response Cache ──────────────────────────────────────────────────────────

const responseCache = new Map<string, { data: unknown; timestamp: number }>();

const CACHE_TTL: Record<string, number> = {
  "/settings": 60_000,
  "/agents": 30_000,
  "/models": 60_000,
  "/providers": 60_000,
  "/sessions": 15_000,
};

function getCacheTTL(path: string): number {
  for (const [prefix, ttl] of Object.entries(CACHE_TTL)) {
    if (path.startsWith(prefix)) return ttl;
  }
  return 0;
}

function getCached<T>(path: string): T | null {
  const entry = responseCache.get(path);
  if (!entry) return null;
  if (Date.now() - entry.timestamp > getCacheTTL(path)) {
    responseCache.delete(path);
    return null;
  }
  return entry.data as T;
}

function setCache(path: string, data: unknown): void {
  if (getCacheTTL(path) > 0) {
    responseCache.set(path, { data, timestamp: Date.now() });
  }
}

export function clearCache(): void {
  responseCache.clear();
}

// ── Offline Queue ───────────────────────────────────────────────────────────

const offlineQueue: QueuedRequest[] = [];

export function getOfflineQueue(): readonly QueuedRequest[] {
  return offlineQueue;
}

export function getOfflineQueueSize(): number {
  return offlineQueue.length;
}

export async function flushOfflineQueue(): Promise<{
  succeeded: number;
  failed: number;
}> {
  let succeeded = 0;
  let failed = 0;
  while (offlineQueue.length > 0) {
    const req = offlineQueue[0];
    try {
      await request(req.path, {
        method: req.method,
        body: req.body ? JSON.stringify(req.body) : undefined,
      });
      offlineQueue.shift();
      succeeded++;
    } catch {
      failed++;
      break;
    }
  }
  return { succeeded, failed };
}

function queueForOffline(method: string, path: string, body?: unknown): void {
  offlineQueue.push({
    id: crypto.randomUUID(),
    method,
    path,
    body,
    timestamp: Date.now(),
  });
}
// ── Token Refresh ─────────────────────────────────────────────────────────────

async function refreshToken(): Promise<string | null> {
  // De-duplicate concurrent refresh calls
  if (_refreshPromise) return _refreshPromise;

  _refreshPromise = (async () => {
    try {
      const response = await fetch(`${BASE_URL}${API_PREFIX}/auth/refresh`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
      });

      if (!response.ok) {
        _token = null;
        return null;
      }

      const data = (await response.json()) as { token: string };
      _token = data.token;
      return _token;
    } catch {
      _token = null;
      return null;
    } finally {
      _refreshPromise = null;
    }
  })();

  return _refreshPromise;
}

// ── Core Request ──────────────────────────────────────────────────────────────

async function doFetch<T>(
  path: string,
  options: RequestInit,
  retried = false,
): Promise<T> {
  const url = `${BASE_URL}${API_PREFIX}${path}`;

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json",
    ...(options.headers as Record<string, string> | undefined),
  };

  if (_token) {
    headers["Authorization"] = `Bearer ${_token}`;
  }

  const response = await fetch(url, { ...options, headers });

  if (response.status === 401 && !retried) {
    const newToken = await refreshToken();
    if (newToken) {
      return doFetch<T>(path, options, true);
    }
  }

  if (!response.ok) {
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      body = await response.text();
    }
    const message =
      typeof body === "object" && body !== null && "error" in body
        ? String((body as Record<string, unknown>).error)
        : `HTTP ${response.status}: ${path}`;
    throw new ApiError(response.status, message, body);
  }

  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const method = (options.method ?? "GET").toUpperCase();

  if (method === "GET") {
    const cached = getCached<T>(path);
    if (cached !== null) return cached;

    try {
      const data = await withRetry(() => doFetch<T>(path, options));
      setCache(path, data);
      return data;
    } catch (error) {
      const stale = getCached<T>(path);
      if (stale !== null) return stale;
      throw error;
    }
  }

  try {
    return await withRetry(() => doFetch<T>(path, options));
  } catch (error) {
    if (!(error instanceof ApiError)) {
      const body =
        options.body !== undefined
          ? JSON.parse(options.body as string)
          : undefined;
      queueForOffline(method, path, body);
    }
    throw error;
  }
}

// ── Health ────────────────────────────────────────────────────────────────────

export const health = {
  /** Health endpoint is at root level, not under /api/v1 */
  get: async (): Promise<HealthResponse> => {
    const res = await fetch(`${BASE_URL}/health`, {
      headers: { Accept: "application/json" },
    });
    if (!res.ok) throw new ApiError(res.status, "Health check failed");
    return res.json() as Promise<HealthResponse>;
  },
};

// ── Onboarding ────────────────────────────────────────────────────────────────

export const onboarding = {
  /** Onboarding endpoints are at root level, not under /api/v1 */
  status: async (): Promise<OnboardingStatus> => {
    const res = await fetch(`${BASE_URL}/onboarding/status`, {
      headers: { Accept: "application/json" },
    });
    if (!res.ok) throw new ApiError(res.status, "Onboarding status failed");
    return res.json() as Promise<OnboardingStatus>;
  },
  complete: async (): Promise<void> => {
    const res = await fetch(`${BASE_URL}/onboarding/complete`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
    });
    if (!res.ok) throw new ApiError(res.status, "Onboarding complete failed");
  },
};

// ── Sessions ──────────────────────────────────────────────────────────────────

export const sessions = {
  list: async (): Promise<Session[]> => {
    const data = await request<{ sessions: Session[]; count: number }>(
      "/sessions",
    );
    return data.sessions ?? [];
  },
  get: (id: string) => request<Session>(`/sessions/${id}`),
  create: (body: CreateSessionRequest = {}) =>
    request<CreateSessionResponse>("/sessions", {
      method: "POST",
      body: JSON.stringify(body),
    }),
  delete: (id: string) =>
    request<void>(`/sessions/${id}`, { method: "DELETE" }),
  rename: (id: string, title: string) =>
    request<Session>(`/sessions/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ title }),
    }),
};

// ── Messages ──────────────────────────────────────────────────────────────────

export const messages = {
  list: async (sessionId: string): Promise<Message[]> => {
    const data = await request<{ messages: Message[]; count: number }>(
      `/sessions/${sessionId}/messages`,
    );
    return data.messages ?? [];
  },

  /**
   * POST a message. Returns a stream_id for subscribing via SSE.
   * For full streaming, use sse.streamMessage() with the returned stream_id.
   */
  send: (body: SendMessageRequest) =>
    request<SendMessageResponse>("/messages", {
      method: "POST",
      body: JSON.stringify({ ...body, stream: true }),
    }),
};

// ── Models ────────────────────────────────────────────────────────────────────

export const models = {
  list: async (): Promise<Model[]> => {
    const data = await request<{
      models: Model[];
      current?: string;
      provider?: string;
    }>("/models");
    return data.models ?? [];
  },
  activate: (name: string, provider = "ollama") =>
    request<Model>(`/models/switch`, {
      method: "POST",
      body: JSON.stringify({ model: name, provider }),
    }),
  download: (name: string) =>
    request<{ job_id: string }>(
      `/models/${encodeURIComponent(name)}/download`,
      {
        method: "POST",
      },
    ),
  delete: (name: string) =>
    request<void>(`/models/${encodeURIComponent(name)}`, { method: "DELETE" }),
};

// ── Providers ─────────────────────────────────────────────────────────────────

export const providers = {
  list: () => request<Provider[]>("/providers"),
  connect: (slug: string, apiKey: string) =>
    request<Provider>(`/providers/${slug}/connect`, {
      method: "POST",
      body: JSON.stringify({ api_key: apiKey }),
    }),
  disconnect: (slug: string) =>
    request<void>(`/providers/${slug}`, { method: "DELETE" }),
};

// ── Agents ────────────────────────────────────────────────────────────────────

export const agents = {
  list: async (): Promise<Agent[]> => {
    const data = await request<AgentsListResponse>("/agents");
    return data.agents ?? [];
  },
  get: (id: string) => request<Agent>(`/agents/${id}`),
  pause: (id: string) =>
    request<Agent>(`/agents/${id}/pause`, { method: "POST" }),
  resume: (id: string) =>
    request<Agent>(`/agents/${id}/resume`, { method: "POST" }),
  /** Terminate (DELETE) an agent — maps to DELETE /api/v1/agents/:id */
  terminate: (id: string) =>
    request<void>(`/agents/${id}`, { method: "DELETE" }),
  /** @deprecated Use terminate() — kept for backward compat */
  cancel: (id: string) => request<void>(`/agents/${id}`, { method: "DELETE" }),
};

// ── Agent Hierarchy ───────────────────────────────────────────────────────────

export const hierarchy = {
  getTree: async (): Promise<HierarchyNode[]> => {
    const data = await request<AgentHierarchyResponse>("/agents/hierarchy");
    return data.hierarchy ?? [];
  },
  update: (agentName: string, body: HierarchyUpdateRequest) =>
    request<HierarchyNode>(
      `/agents/hierarchy/${encodeURIComponent(agentName)}`,
      {
        method: "PUT",
        body: JSON.stringify(body),
      },
    ),
  seed: () =>
    request<{ seeded: number }>("/agents/hierarchy/seed", { method: "POST" }),
  delegate: (agentName: string, to: string, task: string) =>
    request<{ ok: boolean }>(
      `/agents/hierarchy/${encodeURIComponent(agentName)}/delegate`,
      {
        method: "POST",
        body: JSON.stringify({ to, task }),
      },
    ),
};

// ── Orchestrate ───────────────────────────────────────────────────────────────

export const orchestrate = {
  run: (body: OrchestrateRequest) =>
    request<OrchestrateResponse>("/orchestrate", {
      method: "POST",
      body: JSON.stringify(body),
    }),
};

// ── Settings ──────────────────────────────────────────────────────────────────

export const settings = {
  get: () => request<Settings>("/settings"),
  update: (body: Partial<Settings>) =>
    request<Settings>("/settings", {
      method: "PATCH",
      body: JSON.stringify(body),
    }),
};

// ── Skills Marketplace ────────────────────────────────────────────────────────

export const skills = {
  list: async (): Promise<Skill[]> => {
    const data = await request<{ skills: Skill[]; count: number }>(
      "/skills/marketplace",
    );
    return data.skills ?? [];
  },
  get: (id: string) =>
    request<SkillDetail>(`/skills/marketplace/${encodeURIComponent(id)}`),
  toggle: (id: string) =>
    request<{ id: string; enabled: boolean }>(
      `/skills/marketplace/${encodeURIComponent(id)}/toggle`,
      { method: "PUT" },
    ),
  search: async (query: string): Promise<SkillSearchResult[]> => {
    const data = await request<{
      results: SkillSearchResult[];
      count: number;
    }>("/skills/marketplace/search", {
      method: "POST",
      body: JSON.stringify({ query }),
    });
    return data.results ?? [];
  },
  categories: async (): Promise<SkillCategoryCount[]> => {
    const data = await request<{ categories: SkillCategoryCount[] }>(
      "/skills/marketplace/categories",
    );
    return data.categories ?? [];
  },
  bulkEnable: (ids: string[]) =>
    request<{ enabled: string[]; count: number }>(
      "/skills/marketplace/bulk-enable",
      { method: "POST", body: JSON.stringify({ ids }) },
    ),
  bulkDisable: (ids: string[]) =>
    request<{ disabled: string[]; count: number }>(
      "/skills/marketplace/bulk-disable",
      { method: "POST", body: JSON.stringify({ ids }) },
    ),
};

// ── Scheduler ─────────────────────────────────────────────────────────────────

export const scheduler = {
  list: <T>() => request<T>("/scheduler/jobs"),
  get: <T>(id: string) => request<T>(`/scheduler/jobs/${id}`),
  create: <T>(body: unknown) =>
    request<T>("/scheduler/jobs", {
      method: "POST",
      body: JSON.stringify(body),
    }),
  delete: (id: string) =>
    request<void>(`/scheduler/jobs/${id}`, { method: "DELETE" }),
  toggle: <T>(id: string) =>
    request<T>(`/scheduler/jobs/${id}/toggle`, { method: "POST" }),
  runNow: <T>(id: string) =>
    request<T>(`/scheduler/jobs/${id}/run`, { method: "POST" }),
  runs: <T>(id: string, page = 1, limit = 20) =>
    request<T>(`/scheduler/jobs/${id}/runs?page=${page}&limit=${limit}`),
  run: <T>(taskId: string, runId: string) =>
    request<T>(`/scheduler/jobs/${taskId}/runs/${runId}`),
  presets: <T>() => request<T>("/scheduler/presets"),
};

// ── Costs ────────────────────────────────────────────────────────────────────
// ── Costs ─────────────────────────────────────────────────────────────────────

export const costs = {
  summary: () => request<CostSummary>("/costs"),
  byAgent: () => request<{ agents: CostByAgent[] }>("/costs/by-agent"),
  byModel: () => request<{ models: CostByModel[] }>("/costs/by-model"),
  events: (page = 1, perPage = 20, agentName?: string) => {
    const params = new URLSearchParams({
      page: String(page),
      per_page: String(perPage),
    });
    if (agentName) params.set("agent_name", agentName);
    return request<{ events: CostEvent[]; page: number; per_page: number }>(
      `/costs/events?${params}`,
    );
  },
};

// ── Budgets ──────────────────────────────────────────────────────────────────
// ── Budgets ───────────────────────────────────────────────────────────────────

export const budgets = {
  list: () => request<{ budgets: AgentBudget[] }>("/budgets"),
  update: (agentName: string, dailyCents: number, monthlyCents: number) =>
    request<{ status: string }>(`/budgets/${encodeURIComponent(agentName)}`, {
      method: "PUT",
      body: JSON.stringify({
        budget_daily_cents: dailyCents,
        budget_monthly_cents: monthlyCents,
      }),
    }),
  reset: (agentName: string) =>
    request<{ status: string }>(
      `/budgets/${encodeURIComponent(agentName)}/reset`,
      { method: "POST" },
    ),
};

// ── Projects ──────────────────────────────────────────────────────────────────

export const projects = {
  list: async (): Promise<Project[]> => {
    const data = await request<{ projects: Project[] }>("/projects");
    return data.projects ?? [];
  },
  get: (id: number) =>
    request<{ project: Project; goals: Goal[]; task_count: number }>(
      `/projects/${id}`,
    ),
  create: async (body: CreateProjectPayload): Promise<Project> => {
    const data = await request<{ project: Project }>("/projects", {
      method: "POST",
      body: JSON.stringify(body),
    });
    return data.project;
  },
  update: async (
    id: number,
    body: Partial<CreateProjectPayload>,
  ): Promise<Project> => {
    const data = await request<{ project: Project }>(`/projects/${id}`, {
      method: "PUT",
      body: JSON.stringify(body),
    });
    return data.project;
  },
  archive: (id: number) =>
    request<void>(`/projects/${id}`, { method: "DELETE" }),
  tasks: async (id: number): Promise<ProjectTask[]> => {
    const data = await request<{ tasks: ProjectTask[] }>(
      `/projects/${id}/tasks`,
    );
    return data.tasks ?? [];
  },
  linkTask: (projectId: number, taskId: string, goalId?: number) =>
    request<void>(`/projects/${projectId}/tasks/${taskId}`, {
      method: "POST",
      body: JSON.stringify({ goal_id: goalId }),
    }),
  unlinkTask: (projectId: number, taskId: string) =>
    request<void>(`/projects/${projectId}/tasks/${taskId}`, {
      method: "DELETE",
    }),
  goals: async (id: number): Promise<GoalTreeNode[]> => {
    const data = await request<{ goals: GoalTreeNode[] }>(
      `/projects/${id}/goals`,
    );
    return data.goals ?? [];
  },
  createGoal: async (
    projectId: number,
    body: CreateGoalPayload,
  ): Promise<Goal> => {
    const data = await request<{ goal: Goal }>(`/projects/${projectId}/goals`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    return data.goal;
  },
  updateGoal: async (
    projectId: number,
    goalId: number,
    body: Partial<CreateGoalPayload>,
  ): Promise<Goal> => {
    const data = await request<{ goal: Goal }>(
      `/projects/${projectId}/goals/${goalId}`,
      {
        method: "PUT",
        body: JSON.stringify(body),
      },
    );
    return data.goal;
  },
  deleteGoal: (projectId: number, goalId: number) =>
    request<void>(`/projects/${projectId}/goals/${goalId}`, {
      method: "DELETE",
    }),
};

// ── Config Revisions ─────────────────────────────────────────────────────────

export const configRevisions = {
  list: (entityType: string, entityId: string) =>
    request<{ revisions: ConfigRevision[]; count: number }>(
      `/config/revisions/${entityType}/${entityId}`,
    ),
  get: (entityType: string, entityId: string, revisionNumber: number) =>
    request<ConfigRevision>(
      `/config/revisions/${entityType}/${entityId}/${revisionNumber}`,
    ),
  rollback: (entityType: string, entityId: string, revisionNumber: number) =>
    request<ConfigRevision>(
      `/config/revisions/${entityType}/${entityId}/rollback`,
      {
        method: "POST",
        body: JSON.stringify({ revision_number: revisionNumber }),
      },
    ),
  diff: (entityType: string, entityId: string, from: number, to: number) =>
    request<{ diff: ConfigDiff; from: number; to: number }>(
      `/config/revisions/${entityType}/${entityId}/diff?from=${from}&to=${to}`,
    ),
};
