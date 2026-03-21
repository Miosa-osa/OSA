// src/lib/stores/workspace.svelte.ts
// Workspace store — Svelte 5 class with $state fields.
// Manages Canopy workspaces via the OSA backend, with mock fallback
// and Tauri-persisted active workspace selection.

import { load as loadStore } from "@tauri-apps/plugin-store";
import type {
  CreateWorkspacePayload,
  Workspace,
  WorkspaceAgent,
  WorkspaceConfig,
  WorkspaceDetail,
  WorkspaceSkill,
  WorkspaceSummary,
} from "$lib/api/types";
import { BASE_URL, API_PREFIX, getToken } from "$lib/api/client";
import { toastStore } from "$lib/stores/toasts.svelte";

// Re-export for convenience
export type {
  CreateWorkspacePayload,
  Workspace,
  WorkspaceAgent,
  WorkspaceConfig,
  WorkspaceDetail,
  WorkspaceSkill,
  WorkspaceSummary,
};

// ── Constants ─────────────────────────────────────────────────────────────────

const TAURI_STORE_KEY = "osa-active-workspace";
const TAURI_STORE_FILE = "store.json";

// ── Mock data (used when the backend is unreachable) ──────────────────────────

function buildMockWorkspace(name: string, directory: string): Workspace {
  return {
    id: "mock-default",
    name: name || "My Workspace",
    description: "Your primary Canopy workspace",
    directory: directory || "~/",
    agent_count: 0,
    skill_count: 0,
    status: "active",
    created_at: new Date(Date.now() - 86_400_000 * 7).toISOString(),
    updated_at: new Date().toISOString(),
  };
}

// ── API helpers ───────────────────────────────────────────────────────────────

async function apiRequest<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const url = `${BASE_URL}${API_PREFIX}${path}`;
  const token = getToken();
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json",
    ...(options.headers as Record<string, string> | undefined),
  };
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(url, { ...options, headers });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${path}`);
  if (res.status === 204) return undefined as T;
  return res.json() as Promise<T>;
}

// ── WorkspaceStore Class ──────────────────────────────────────────────────────

class WorkspaceStore {
  // ── State ─────────────────────────────────────────────────────────────────

  workspaces = $state<Workspace[]>([]);
  activeWorkspace = $state<Workspace | null>(null);
  loading = $state(false);
  error = $state<string | null>(null);

  // ── Derived ──────────────────────────────────────────────────────────────

  activeId = $derived(this.activeWorkspace?.id ?? null);

  activeCount = $derived(
    this.workspaces.filter((w) => w.status === "active").length,
  );

  // ── Tauri store helpers ────────────────────────────────────────────────────

  private async getPersistedActiveId(): Promise<string | null> {
    try {
      const store = await loadStore(TAURI_STORE_FILE, {
        autoSave: true,
        defaults: {},
      });
      return (await store.get<string>(TAURI_STORE_KEY)) ?? null;
    } catch {
      return null;
    }
  }

  private async persistActiveId(id: string): Promise<void> {
    try {
      const store = await loadStore(TAURI_STORE_FILE, {
        autoSave: true,
        defaults: {},
      });
      await store.set(TAURI_STORE_KEY, id);
      await store.save();
    } catch {
      // Non-fatal — active workspace is kept in-memory
    }
  }

  private async getOnboardingWorkspaceMeta(): Promise<{
    name: string;
    directory: string;
  }> {
    try {
      const store = await loadStore(TAURI_STORE_FILE, {
        autoSave: true,
        defaults: {},
      });
      const name = (await store.get<string>("workspaceName")) ?? "My Workspace";
      const directory = (await store.get<string>("workingDirectory")) ?? "~/";
      return { name, directory };
    } catch {
      return { name: "My Workspace", directory: "~/" };
    }
  }

  // ── List / fetch actions ───────────────────────────────────────────────────

  async fetchWorkspaces(): Promise<void> {
    this.loading = true;
    this.error = null;
    try {
      const data = await apiRequest<{ workspaces: Workspace[]; count: number }>(
        "/workspaces",
      );
      this.workspaces = data.workspaces ?? [];

      // Restore previously active workspace from Tauri store
      const storedId = await this.getPersistedActiveId();
      if (storedId) {
        const found = this.workspaces.find((w) => w.id === storedId);
        this.activeWorkspace = found ?? this.workspaces[0] ?? null;
      } else {
        this.activeWorkspace = this.workspaces[0] ?? null;
      }
    } catch {
      // Backend offline — fall back to mock workspace built from onboarding data
      const meta = await this.getOnboardingWorkspaceMeta();
      const mock = buildMockWorkspace(meta.name, meta.directory);
      this.workspaces = [mock];
      this.activeWorkspace = mock;
      toastStore.warning("Backend offline — some features unavailable");
    } finally {
      this.loading = false;
    }
  }

  /** POST /api/v1/workspaces — called by CreateWorkspaceModal. */
  async createWorkspace(
    payload: CreateWorkspacePayload,
  ): Promise<Workspace | null> {
    this.error = null;
    try {
      // The Canopy API expects `path`, not `directory`
      const body = {
        name: payload.name,
        description: payload.description,
        path: payload.directory,
      };
      const data = await apiRequest<{ workspace: Workspace }>("/workspaces", {
        method: "POST",
        body: JSON.stringify(body),
      });
      const workspace = data.workspace;
      this.workspaces = [workspace, ...this.workspaces];
      return workspace;
    } catch (e) {
      this.error =
        e instanceof Error ? e.message : "Failed to create workspace";
      toastStore.error("Failed to create workspace");
      return null;
    }
  }

  /**
   * GET /api/v1/workspaces/:id — returns workspace detail with
   * system_md and company_md fields.
   */
  async fetchWorkspaceDetail(id: string): Promise<WorkspaceDetail | null> {
    try {
      return await apiRequest<WorkspaceDetail>(`/workspaces/${id}`);
    } catch (e) {
      this.error =
        e instanceof Error ? e.message : "Failed to fetch workspace detail";
      toastStore.error("Failed to load workspace detail");
      return null;
    }
  }

  /**
   * PATCH /api/v1/workspaces/:id — update name and/or description.
   */
  async updateWorkspace(
    id: string,
    changes: { name?: string; description?: string },
  ): Promise<Workspace | null> {
    try {
      const updated = await apiRequest<Workspace>(`/workspaces/${id}`, {
        method: "PATCH",
        body: JSON.stringify(changes),
      });
      this.workspaces = this.workspaces.map((w) => (w.id === id ? updated : w));
      if (this.activeWorkspace?.id === id) {
        this.activeWorkspace = updated;
      }
      return updated;
    } catch (e) {
      this.error =
        e instanceof Error ? e.message : "Failed to update workspace";
      toastStore.error("Failed to update workspace");
      return null;
    }
  }

  /**
   * POST /api/v1/workspaces/:id/activate — sets the workspace as active on
   * the backend, then persists the selection in the Tauri store.
   */
  async switchWorkspace(id: string): Promise<void> {
    const workspace = this.workspaces.find((w) => w.id === id);
    if (!workspace) return;

    this.activeWorkspace = workspace;
    await this.persistActiveId(id);

    try {
      await apiRequest<void>(`/workspaces/${id}/activate`, { method: "POST" });
    } catch {
      // Non-fatal — UI already reflects the switch; backend will sync on next request
      toastStore.warning("Could not notify backend of workspace switch");
    }
  }

  /**
   * GET /api/v1/workspaces/:id/agents — returns agents scoped to this workspace.
   */
  async fetchWorkspaceAgents(id: string): Promise<WorkspaceAgent[]> {
    try {
      const data = await apiRequest<{
        agents: WorkspaceAgent[];
        count: number;
      }>(`/workspaces/${id}/agents`);
      return data.agents ?? [];
    } catch (e) {
      this.error =
        e instanceof Error ? e.message : "Failed to fetch workspace agents";
      toastStore.error("Failed to load workspace agents");
      return [];
    }
  }

  /**
   * GET /api/v1/workspaces/:id/skills — returns skills scoped to this workspace.
   */
  async fetchWorkspaceSkills(id: string): Promise<WorkspaceSkill[]> {
    try {
      const data = await apiRequest<{
        skills: WorkspaceSkill[];
        count: number;
      }>(`/workspaces/${id}/skills`);
      return data.skills ?? [];
    } catch (e) {
      this.error =
        e instanceof Error ? e.message : "Failed to fetch workspace skills";
      toastStore.error("Failed to load workspace skills");
      return [];
    }
  }

  /**
   * GET /api/v1/workspaces/:id/config — returns SYSTEM.md and COMPANY.md
   * content for this workspace.
   */
  async fetchWorkspaceConfig(id: string): Promise<WorkspaceConfig | null> {
    try {
      return await apiRequest<WorkspaceConfig>(`/workspaces/${id}/config`);
    } catch (e) {
      this.error =
        e instanceof Error ? e.message : "Failed to fetch workspace config";
      toastStore.error("Failed to load workspace config");
      return null;
    }
  }

  /**
   * DELETE /api/v1/workspaces/:id — removes the workspace from tracking.
   * Optimistically removes from local state and rolls back on failure.
   */
  async deleteWorkspace(id: string): Promise<void> {
    const previous = this.workspaces;
    this.workspaces = this.workspaces.filter((w) => w.id !== id);

    if (this.activeWorkspace?.id === id) {
      this.activeWorkspace =
        this.workspaces.find((w) => w.status === "active") ?? null;
    }

    try {
      await apiRequest<void>(`/workspaces/${id}`, { method: "DELETE" });
    } catch {
      this.workspaces = previous;
      toastStore.error("Failed to remove workspace");
    }
  }

  // ── Utility ───────────────────────────────────────────────────────────────

  clearError(): void {
    this.error = null;
  }
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const workspaceStore = new WorkspaceStore();
