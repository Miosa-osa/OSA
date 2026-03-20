// src/lib/stores/plan.svelte.ts
// Plan review store — queues a plan text for user approval, rejection, or inline edit.
// Uses the same promise-based resolution pattern as permissionStore.

import { BASE_URL, API_PREFIX, getToken } from "$lib/api/client";

// ── Types ─────────────────────────────────────────────────────────────────────

export type PlanDecision =
  | "approve"
  | "reject"
  | { action: "edit"; text: string };

export interface PendingPlan {
  /** The raw plan text (markdown) */
  text: string;
  /** Session the plan belongs to */
  sessionId: string;
  /** Resolves with the user's decision */
  resolve: (decision: PlanDecision) => void;
}

// ── Plan Store ────────────────────────────────────────────────────────────────

class PlanStore {
  /** Currently displayed plan, or null when idle */
  pendingPlan = $state<PendingPlan | null>(null);

  /** True while the panel is visible */
  get isVisible(): boolean {
    return this.pendingPlan !== null;
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /**
   * Display the plan review panel and wait for a user decision.
   * If a plan is already pending, the previous one is rejected before showing
   * the new one.
   */
  showPlan(text: string, sessionId: string): Promise<PlanDecision> {
    // Reject any prior plan without showing it
    if (this.pendingPlan) {
      this.pendingPlan.resolve("reject");
    }

    return new Promise<PlanDecision>((resolve) => {
      this.pendingPlan = { text, sessionId, resolve };
    });
  }

  /** User approved the plan as-is. */
  approve(): void {
    this.#resolve("approve");
  }

  /** User rejected the plan. */
  reject(): void {
    this.#resolve("reject");
  }

  /** User submitted an edited version of the plan. */
  submitEdit(editedText: string): void {
    this.#resolve({ action: "edit", text: editedText });
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  #resolve(decision: PlanDecision): void {
    if (!this.pendingPlan) return;

    const { resolve, sessionId } = this.pendingPlan;

    // Clear state immediately so the panel unmounts
    this.pendingPlan = null;

    // Resolve the awaiting promise
    resolve(decision);

    // POST the decision to the backend (fire-and-forget)
    void this.#postDecision(sessionId, decision);
  }

  async #postDecision(
    sessionId: string,
    decision: PlanDecision,
  ): Promise<void> {
    try {
      const token = getToken();
      const body =
        typeof decision === "string"
          ? { decision }
          : { decision: decision.action, plan: decision.text };

      await fetch(`${BASE_URL}${API_PREFIX}/sessions/${sessionId}/plan`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify(body),
      });
    } catch {
      // Non-fatal — the promise was already resolved; the backend
      // will time-out and treat silence as rejection if needed.
    }
  }
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const planStore = new PlanStore();
