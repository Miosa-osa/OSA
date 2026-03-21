// src/lib/stores/agents.svelte.ts
// Agents store — Svelte 5 class with $state fields.
// Manages agent list with polling and SSE event integration.

import type { Agent, AgentStatus, HierarchyNode } from "$lib/api/types";
import {
  agents as agentsApi,
  hierarchy as hierarchyApi,
  ApiError,
} from "$lib/api/client";
import { toastStore } from "$lib/stores/toasts.svelte";

// ── Tree types ─────────────────────────────────────────────────────────────────

export interface AgentTreeNode {
  agent: Agent;
  /** Wave / depth level (0 = orchestrator root) */
  wave: number;
  /** ID of the parent agent, or null for the root */
  parentId: string | null;
  /** Direct children */
  children: AgentTreeNode[];
}

// ── Agents Store Class ────────────────────────────────────────────────────────

class AgentsStore {
  agents = $state<Agent[]>([]);
  hierarchy = $state<HierarchyNode[]>([]);
  loading = $state(false);
  hierarchyLoading = $state(false);
  error = $state<string | null>(null);
  lastUpdated = $state<Date | null>(null);

  // ── Derived counts ──────────────────────────────────────────────────────────

  runningCount = $derived(
    this.agents.filter((a) => a.status === "running" || a.status === "queued")
      .length,
  );

  completedCount = $derived(
    this.agents.filter((a) => a.status === "done").length,
  );

  failedCount = $derived(
    this.agents.filter((a) => a.status === "error").length,
  );

  idleCount = $derived(this.agents.filter((a) => a.status === "idle").length);

  totalCount = $derived(this.agents.length);

  // ── Agent tree (flat list → hierarchical structure) ──────────────────────────
  //
  // The Agent API type has no parentId/wave fields yet. We infer hierarchy from
  // agent name conventions and creation order:
  //   - First agent (or one named "orchestrator"/"master") → root (wave 0)
  //   - Subsequent agents → children of the most-recent ancestor wave
  //   - Agents spawned in the same "batch" share a wave number (detected via
  //     created_at timestamps within a 2-second window)
  //
  // When the backend adds parentId/wave fields they can be used directly.

  agentTree = $derived.by((): AgentTreeNode[] => {
    if (this.agents.length === 0) return [];

    // Sort agents by creation time ascending
    const sorted = [...this.agents].sort(
      (a, b) =>
        new Date(a.created_at).getTime() - new Date(b.created_at).getTime(),
    );

    // Identify root: orchestrator/master named agent, or the earliest created
    const rootCandidate =
      sorted.find((a) => {
        const lower = a.name.toLowerCase();
        return (
          lower.includes("orchestrat") ||
          lower.includes("master") ||
          lower.includes("primary")
        );
      }) ?? sorted[0];

    // Assign wave numbers via BFS order using 2-second timestamp batching
    const waveMap = new Map<string, number>();
    const parentMap = new Map<string, string | null>();

    waveMap.set(rootCandidate.id, 0);
    parentMap.set(rootCandidate.id, null);

    const remaining = sorted.filter((a) => a.id !== rootCandidate.id);

    // Simple greedy wave assignment:
    // Agents created within 2 seconds of each other → same wave
    // Each wave's parent is the root (wave 0) if wave 1, otherwise previous wave's last agent
    let currentWave = 1;
    let waveStartTime = remaining[0]
      ? new Date(remaining[0].created_at).getTime()
      : 0;

    // Find the most recent agent in the previous wave to use as parent
    const lastInWave = new Map<number, string>();
    lastInWave.set(0, rootCandidate.id);

    for (const agent of remaining) {
      const t = new Date(agent.created_at).getTime();
      if (t - waveStartTime > 2000) {
        // New wave: bump counter, record start time
        currentWave += 1;
        waveStartTime = t;
      }
      waveMap.set(agent.id, currentWave);

      // Parent: last agent in the preceding wave (or root)
      const parentWave = currentWave - 1;
      const parentId = lastInWave.get(parentWave) ?? rootCandidate.id;
      parentMap.set(agent.id, parentId);
      lastInWave.set(currentWave, agent.id);
    }

    // Build flat list of AgentTreeNode (children arrays populated below)
    const nodeMap = new Map<string, AgentTreeNode>();
    for (const agent of sorted) {
      nodeMap.set(agent.id, {
        agent,
        wave: waveMap.get(agent.id) ?? 0,
        parentId: parentMap.get(agent.id) ?? null,
        children: [],
      });
    }

    // Wire up children
    for (const node of nodeMap.values()) {
      if (node.parentId) {
        const parent = nodeMap.get(node.parentId);
        parent?.children.push(node);
      }
    }

    // Return flat list (AgentTree uses wave for layout, not recursive traversal)
    return [...nodeMap.values()];
  });

  // ── Fetch ───────────────────────────────────────────────────────────────────

  async fetchAgents(): Promise<void> {
    this.loading = true;
    this.error = null;
    try {
      const result = await agentsApi.list();
      this.agents = result;
      this.lastUpdated = new Date();
    } catch (err) {
      this.error =
        err instanceof Error ? err.message : "Failed to fetch agents";
      if (
        err instanceof TypeError ||
        (err instanceof Error && err.message === "Failed to fetch")
      ) {
        if (!this.error?.includes("offline"))
          toastStore.warning("Backend offline — some features unavailable");
      } else {
        const status = err instanceof ApiError ? ` (${err.status})` : "";
        toastStore.error(`Failed to load agents${status}`);
      }
    } finally {
      this.loading = false;
    }
  }

  async fetchHierarchy(): Promise<void> {
    this.hierarchyLoading = true;
    try {
      this.hierarchy = await hierarchyApi.getTree();
    } catch (err) {
      if (
        err instanceof TypeError ||
        (err instanceof Error && err.message === "Failed to fetch")
      ) {
        toastStore.warning("Backend offline — some features unavailable");
      } else {
        const status = err instanceof ApiError ? ` (${err.status})` : "";
        toastStore.error(`Failed to load agent hierarchy${status}`);
      }
    } finally {
      this.hierarchyLoading = false;
    }
  }

  async pauseAgent(id: string): Promise<void> {
    this.setAgentStatus(id, "queued");
    try {
      const updated = await agentsApi.pause(id);
      const idx = this.agents.findIndex((a) => a.id === id);
      if (idx !== -1) this.agents.splice(idx, 1, updated);
    } catch (err) {
      // Revert optimistic update by re-fetching
      void this.fetchAgents();
      if (
        err instanceof TypeError ||
        (err instanceof Error && err.message === "Failed to fetch")
      ) {
        toastStore.warning("Backend offline — some features unavailable");
      } else {
        const status = err instanceof ApiError ? ` (${err.status})` : "";
        toastStore.error(`Failed to pause agent${status}`);
      }
    }
  }

  async resumeAgent(id: string): Promise<void> {
    this.setAgentStatus(id, "running");
    try {
      const updated = await agentsApi.resume(id);
      const idx = this.agents.findIndex((a) => a.id === id);
      if (idx !== -1) this.agents.splice(idx, 1, updated);
    } catch (err) {
      void this.fetchAgents();
      if (
        err instanceof TypeError ||
        (err instanceof Error && err.message === "Failed to fetch")
      ) {
        toastStore.warning("Backend offline — some features unavailable");
      } else {
        const status = err instanceof ApiError ? ` (${err.status})` : "";
        toastStore.error(`Failed to resume agent${status}`);
      }
    }
  }

  async terminateAgent(id: string): Promise<void> {
    // Optimistic: remove from list immediately
    const prev = this.agents.find((a) => a.id === id);
    this.agents = this.agents.filter((a) => a.id !== id);
    try {
      await agentsApi.terminate(id);
      this.lastUpdated = new Date();
    } catch (err) {
      // Restore on failure
      if (prev) this.agents = [...this.agents, prev];
      if (
        err instanceof TypeError ||
        (err instanceof Error && err.message === "Failed to fetch")
      ) {
        toastStore.warning("Backend offline — some features unavailable");
      } else {
        const status = err instanceof ApiError ? ` (${err.status})` : "";
        toastStore.error(`Failed to terminate agent${status}`);
      }
    }
  }

  // ── SSE event handler ───────────────────────────────────────────────────────

  handleEvent(event: { type: string; payload?: unknown }): void {
    if (
      event.type === "agent_started" ||
      event.type === "agent_updated" ||
      event.type === "agent_done" ||
      event.type === "agent_error"
    ) {
      const incoming = event.payload as Agent | undefined;
      if (!incoming?.id) return;

      const idx = this.agents.findIndex((a) => a.id === incoming.id);
      if (idx !== -1) {
        // Splice for fine-grained reactivity
        this.agents.splice(idx, 1, incoming);
      } else {
        this.agents.push(incoming);
      }
      this.lastUpdated = new Date();
    }

    if (event.type === "agent_removed") {
      const payload = event.payload as { id?: string } | undefined;
      if (payload?.id) {
        this.agents = this.agents.filter((a) => a.id !== payload.id);
        this.lastUpdated = new Date();
      }
    }
  }

  // ── Optimistic status update ────────────────────────────────────────────────

  setAgentStatus(id: string, status: AgentStatus): void {
    const idx = this.agents.findIndex((a) => a.id === id);
    if (idx !== -1) {
      this.agents[idx] = { ...this.agents[idx], status };
    }
  }
}

export const agentsStore = new AgentsStore();
