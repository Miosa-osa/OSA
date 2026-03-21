// src/lib/stores/issues.svelte.ts
// Issue/Ticket management store — Svelte 5 class with $state fields.
// Manages the agent work inbox: CRUD, filters, sorting, comments.

import { BASE_URL, API_PREFIX, getToken } from "$lib/api/client";
import { toastStore } from "$lib/stores/toasts.svelte";

// ── Types ──────────────────────────────────────────────────────────────────────

export type IssueStatus = "open" | "in_progress" | "done" | "blocked";
export type IssuePriority = "low" | "medium" | "high" | "critical";
export type IssueSortField = "created_at" | "priority" | "updated_at";

export interface IssueComment {
  id: string;
  author: string;
  content: string;
  created_at: string;
}

export interface IssueSubtask {
  id: string;
  title: string;
  done: boolean;
}

export interface Issue {
  id: string;
  title: string;
  description: string;
  status: IssueStatus;
  priority: IssuePriority;
  assignee?: string;
  labels: string[];
  created_at: string;
  updated_at: string;
  comments: IssueComment[];
  subtasks: IssueSubtask[];
}

export interface CreateIssuePayload {
  title: string;
  description?: string;
  status?: IssueStatus;
  priority?: IssuePriority;
  assignee?: string;
  labels?: string[];
}

export interface UpdateIssuePayload {
  title?: string;
  description?: string;
  status?: IssueStatus;
  priority?: IssuePriority;
  assignee?: string;
  labels?: string[];
}

// ── Priority weight for sorting ───────────────────────────────────────────────

const PRIORITY_WEIGHT: Record<IssuePriority, number> = {
  critical: 4,
  high: 3,
  medium: 2,
  low: 1,
};

// ── Internal fetch helper ──────────────────────────────────────────────────────

async function issueRequest<T>(
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
  if (!res.ok) {
    let body: unknown;
    try {
      body = await res.json();
    } catch {
      body = await res.text();
    }
    const msg =
      typeof body === "object" && body !== null && "error" in body
        ? String((body as Record<string, unknown>).error)
        : `HTTP ${res.status}: ${path}`;
    throw new Error(msg);
  }
  if (res.status === 204) return undefined as T;
  return res.json() as Promise<T>;
}

// ── IssuesStore Class ──────────────────────────────────────────────────────────

class IssuesStore {
  issues = $state<Issue[]>([]);
  loading = $state(false);
  error = $state<string | null>(null);
  selectedIssue = $state<Issue | null>(null);

  // ── Filters & Sort ──────────────────────────────────────────────────────────

  filterStatus = $state<IssueStatus | "all">("all");
  filterPriority = $state<IssuePriority | "all">("all");
  filterAssignee = $state<string | "all">("all");
  sortBy = $state<IssueSortField>("created_at");

  // ── Derived counts ──────────────────────────────────────────────────────────

  openCount = $derived(this.issues.filter((i) => i.status === "open").length);
  inProgressCount = $derived(
    this.issues.filter((i) => i.status === "in_progress").length,
  );
  doneCount = $derived(this.issues.filter((i) => i.status === "done").length);
  blockedCount = $derived(
    this.issues.filter((i) => i.status === "blocked").length,
  );

  // ── Filtered + sorted issues ────────────────────────────────────────────────

  filteredIssues = $derived.by((): Issue[] => {
    let result = this.issues;

    if (this.filterStatus !== "all") {
      result = result.filter((i) => i.status === this.filterStatus);
    }
    if (this.filterPriority !== "all") {
      result = result.filter((i) => i.priority === this.filterPriority);
    }
    if (this.filterAssignee !== "all") {
      result = result.filter((i) => i.assignee === this.filterAssignee);
    }

    const sorted = [...result];
    switch (this.sortBy) {
      case "priority":
        sorted.sort(
          (a, b) => PRIORITY_WEIGHT[b.priority] - PRIORITY_WEIGHT[a.priority],
        );
        break;
      case "updated_at":
        sorted.sort(
          (a, b) =>
            new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime(),
        );
        break;
      case "created_at":
      default:
        sorted.sort(
          (a, b) =>
            new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
        );
    }
    return sorted;
  });

  // ── CRUD Methods ────────────────────────────────────────────────────────────

  async fetchIssues(): Promise<void> {
    this.loading = true;
    this.error = null;
    try {
      const data = await issueRequest<{ issues: Issue[] }>(
        "/command-center/issues",
      );
      this.issues = data.issues ?? [];
    } catch (e) {
      this.error = e instanceof Error ? e.message : "Failed to load issues";
      // Graceful degradation — keep existing data, just surface the error
      if (
        e instanceof TypeError ||
        (e instanceof Error && e.message === "Failed to fetch")
      ) {
        toastStore.warning("Backend offline — some features unavailable");
      } else {
        toastStore.error("Failed to load issues");
      }
    } finally {
      this.loading = false;
    }
  }

  async createIssue(payload: CreateIssuePayload): Promise<Issue | null> {
    try {
      const data = await issueRequest<{ issue: Issue }>(
        "/command-center/issues",
        {
          method: "POST",
          body: JSON.stringify(payload),
        },
      );
      const issue = data.issue;
      this.issues = [issue, ...this.issues];
      return issue;
    } catch (e) {
      this.error = e instanceof Error ? e.message : "Failed to create issue";
      toastStore.error("Failed to create issue");
      return null;
    }
  }

  async updateIssue(id: string, payload: UpdateIssuePayload): Promise<void> {
    const idx = this.issues.findIndex((i) => i.id === id);
    if (idx === -1) return;

    // Optimistic update
    const prev = this.issues[idx];
    this.issues[idx] = {
      ...prev,
      ...payload,
      updated_at: new Date().toISOString(),
    };
    if (this.selectedIssue?.id === id) {
      this.selectedIssue = this.issues[idx];
    }

    try {
      const data = await issueRequest<{ issue: Issue }>(
        `/command-center/issues/${id}`,
        {
          method: "PATCH",
          body: JSON.stringify(payload),
        },
      );
      this.issues[idx] = data.issue;
      if (this.selectedIssue?.id === id) {
        this.selectedIssue = data.issue;
      }
    } catch {
      // Rollback
      this.issues[idx] = prev;
      if (this.selectedIssue?.id === id) {
        this.selectedIssue = prev;
      }
    }
  }

  async deleteIssue(id: string): Promise<void> {
    const prev = [...this.issues];
    this.issues = this.issues.filter((i) => i.id !== id);
    if (this.selectedIssue?.id === id) {
      this.selectedIssue = null;
    }

    try {
      await issueRequest<void>(`/command-center/issues/${id}`, {
        method: "DELETE",
      });
    } catch {
      // Rollback
      this.issues = prev;
    }
  }

  // ── Comment Methods ─────────────────────────────────────────────────────────

  async addComment(issueId: string, content: string): Promise<void> {
    try {
      const data = await issueRequest<{ comment: IssueComment }>(
        `/command-center/issues/${issueId}/comments`,
        {
          method: "POST",
          body: JSON.stringify({ content }),
        },
      );
      const idx = this.issues.findIndex((i) => i.id === issueId);
      if (idx !== -1) {
        this.issues[idx] = {
          ...this.issues[idx],
          comments: [...this.issues[idx].comments, data.comment],
        };
        if (this.selectedIssue?.id === issueId) {
          this.selectedIssue = this.issues[idx];
        }
      }
    } catch (e) {
      this.error = e instanceof Error ? e.message : "Failed to add comment";
    }
  }

  async fetchComments(issueId: string): Promise<IssueComment[]> {
    try {
      const data = await issueRequest<{ comments: IssueComment[] }>(
        `/command-center/issues/${issueId}/comments`,
      );
      return data.comments ?? [];
    } catch {
      return [];
    }
  }

  // ── Selection ───────────────────────────────────────────────────────────────

  selectIssue(issue: Issue | null): void {
    this.selectedIssue = issue;
  }

  // ── Filter / Sort setters ────────────────────────────────────────────────────

  setFilterStatus(status: IssueStatus | "all"): void {
    this.filterStatus = status;
  }

  setFilterPriority(priority: IssuePriority | "all"): void {
    this.filterPriority = priority;
  }

  setFilterAssignee(assignee: string | "all"): void {
    this.filterAssignee = assignee;
  }

  setSortBy(sort: IssueSortField): void {
    this.sortBy = sort;
  }
}

// ── Singleton export ───────────────────────────────────────────────────────────

export const issuesStore = new IssuesStore();
