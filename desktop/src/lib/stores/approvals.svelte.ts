import { BASE_URL, API_PREFIX, getToken } from "$lib/api/client";
import type { Approval } from "$lib/api/types";

function authHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  const token = getToken();
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }
  return headers;
}

class ApprovalsStore {
  approvals = $state<Approval[]>([]);
  loading = $state(false);
  error = $state<string | null>(null);

  pendingCount = $derived(
    this.approvals.filter((a) => a.status === "pending").length,
  );

  pendingApprovals = $derived(
    this.approvals.filter((a) => a.status === "pending"),
  );

  async fetchApprovals(): Promise<void> {
    this.loading = true;
    this.error = null;
    try {
      const res = await fetch(`${BASE_URL}${API_PREFIX}/approvals`, {
        headers: authHeaders(),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}: /api/v1/approvals`);
      const data = await res.json();
      this.approvals = data.approvals ?? [];
    } catch (err) {
      this.error =
        err instanceof Error ? err.message : "Failed to fetch approvals";
    } finally {
      this.loading = false;
    }
  }

  async approve(id: number, notes: string): Promise<void> {
    await fetch(`${BASE_URL}${API_PREFIX}/approvals/${id}/approve`, {
      method: "POST",
      headers: authHeaders(),
      body: JSON.stringify({ notes, resolved_by: "operator" }),
    });
    await this.fetchApprovals();
  }

  async reject(id: number, notes: string): Promise<void> {
    await fetch(`${BASE_URL}${API_PREFIX}/approvals/${id}/reject`, {
      method: "POST",
      headers: authHeaders(),
      body: JSON.stringify({ notes, resolved_by: "operator" }),
    });
    await this.fetchApprovals();
  }

  async requestRevision(id: number, notes: string): Promise<void> {
    await fetch(`${BASE_URL}${API_PREFIX}/approvals/${id}/request-revision`, {
      method: "POST",
      headers: authHeaders(),
      body: JSON.stringify({ notes, resolved_by: "operator" }),
    });
    await this.fetchApprovals();
  }
}

export const approvalsStore = new ApprovalsStore();
