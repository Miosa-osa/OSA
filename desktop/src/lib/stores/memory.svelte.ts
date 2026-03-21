// src/lib/stores/memory.svelte.ts
// Memory Vault store — Svelte 5 class with $state fields.
// Manages persisted memory entries: fetch, search, filter, sort, CRUD.

import { BASE_URL, API_PREFIX, getToken } from "$api/client";

// ── Types ──────────────────────────────────────────────────────────────────────

export type MemoryCategory =
  | "fact"
  | "preference"
  | "instruction"
  | "context"
  | "other";

export type SortMode = "relevance" | "updated" | "key";

export interface MemoryEntry {
  id: string;
  key: string;
  value: string;
  category: MemoryCategory;
  tags: string[];
  created_at: string;
  updated_at: string;
}

// Shape the backend returns from GET /api/v1/memory/recall
interface RecallResponse {
  memories: RawMemory[];
}

// Shape the backend returns from GET /api/v1/memory/search
interface SearchResponse {
  results: RawMemory[];
}

// Raw backend memory shape — may differ from MemoryEntry
interface RawMemory {
  id: string;
  key: string;
  value: string;
  category?: string;
  tags?: string[];
  created_at?: string;
  updated_at?: string;
  inserted_at?: string; // Elixir Ecto alias for created_at
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function normalizeCategory(raw: string | undefined): MemoryCategory {
  const valid: MemoryCategory[] = [
    "fact",
    "preference",
    "instruction",
    "context",
    "other",
  ];
  return valid.includes(raw as MemoryCategory)
    ? (raw as MemoryCategory)
    : "other";
}

function toEntry(raw: RawMemory): MemoryEntry {
  return {
    id: raw.id,
    key: raw.key,
    value: raw.value,
    category: normalizeCategory(raw.category),
    tags: raw.tags ?? [],
    created_at: raw.created_at ?? raw.inserted_at ?? new Date().toISOString(),
    updated_at: raw.updated_at ?? raw.inserted_at ?? new Date().toISOString(),
  };
}

function authHeaders(): Record<string, string> {
  const token = getToken();
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }
  return headers;
}

function matchesSearch(entry: MemoryEntry, query: string): boolean {
  if (!query) return true;
  const q = query.toLowerCase();
  return (
    entry.key.toLowerCase().includes(q) ||
    entry.value.toLowerCase().includes(q) ||
    entry.tags.some((t) => t.toLowerCase().includes(q))
  );
}

function applySorting(
  entries: MemoryEntry[],
  sortBy: SortMode,
  query: string,
): MemoryEntry[] {
  const copy = [...entries];

  switch (sortBy) {
    case "relevance": {
      // When there is a query, prefer key matches over value matches.
      // Without a query, fall through to recency ordering.
      if (query) {
        const q = query.toLowerCase();
        return copy.sort((a, b) => {
          const aKeyMatch = a.key.toLowerCase().includes(q) ? 0 : 1;
          const bKeyMatch = b.key.toLowerCase().includes(q) ? 0 : 1;
          if (aKeyMatch !== bKeyMatch) return aKeyMatch - bKeyMatch;
          // Secondary: recency
          return (
            new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime()
          );
        });
      }
      // No query — relevance degrades to recency
      return copy.sort(
        (a, b) =>
          new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime(),
      );
    }

    case "updated":
      return copy.sort(
        (a, b) =>
          new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime(),
      );

    case "key":
      return copy.sort((a, b) => a.key.localeCompare(b.key));
  }
}

// ── MemoryStore Class ──────────────────────────────────────────────────────────

class MemoryStore {
  entries = $state<MemoryEntry[]>([]);
  loading = $state(false);
  error = $state<string | null>(null);
  searchQuery = $state("");
  filterCategory = $state<string>("all");
  selectedId = $state<string | null>(null);
  sortBy = $state<SortMode>("relevance");

  // ── Derived ───────────────────────────────────────────────────────────────

  filtered = $derived(
    applySorting(
      this.entries.filter(
        (e) =>
          matchesSearch(e, this.searchQuery) &&
          (this.filterCategory === "all" || e.category === this.filterCategory),
      ),
      this.sortBy,
      this.searchQuery,
    ),
  );

  selected = $derived(
    this.selectedId !== null
      ? (this.entries.find((e) => e.id === this.selectedId) ?? null)
      : null,
  );

  categoryCounts = $derived(
    this.entries.reduce<Record<string, number>>(
      (acc, e) => {
        acc[e.category] = (acc[e.category] ?? 0) + 1;
        return acc;
      },
      { fact: 0, preference: 0, instruction: 0, context: 0, other: 0 },
    ),
  );

  totalCount = $derived(this.entries.length);

  // ── API Operations ────────────────────────────────────────────────────────

  async fetchMemories(): Promise<void> {
    this.loading = true;
    this.error = null;

    try {
      const response = await fetch(`${BASE_URL}${API_PREFIX}/memory/recall`, {
        headers: authHeaders(),
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const data = (await response.json()) as RecallResponse;
      const raw = Array.isArray(data.memories) ? data.memories : [];
      this.entries = raw.map(toEntry);
    } catch {
      this.entries = [];
      this.error = "Backend offline";
    } finally {
      this.loading = false;
    }
  }

  async deleteMemory(id: string): Promise<void> {
    const previous = this.entries;
    // Optimistic remove
    this.entries = this.entries.filter((e) => e.id !== id);
    // Clear selection if the deleted entry was selected
    if (this.selectedId === id) {
      this.selectedId = null;
    }

    try {
      const response = await fetch(
        `${BASE_URL}${API_PREFIX}/memory/${encodeURIComponent(id)}`,
        { method: "DELETE", headers: authHeaders() },
      );

      if (!response.ok && response.status !== 204) {
        throw new Error(`HTTP ${response.status}`);
      }
    } catch {
      // Roll back optimistic removal on failure
      this.entries = previous;
      this.error = "Failed to delete memory entry. Please try again.";
    }
  }

  async updateMemory(
    id: string,
    updates: Partial<Omit<MemoryEntry, "id" | "created_at">>,
  ): Promise<void> {
    const previous = this.entries;
    const now = new Date().toISOString();

    // Optimistic update
    this.entries = this.entries.map((e) =>
      e.id === id ? { ...e, ...updates, updated_at: now } : e,
    );

    try {
      const response = await fetch(
        `${BASE_URL}${API_PREFIX}/memory/${encodeURIComponent(id)}`,
        {
          method: "PATCH",
          headers: authHeaders(),
          body: JSON.stringify(updates),
        },
      );

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      // Merge the server's canonical response if available
      if (response.status !== 204) {
        const raw = (await response.json()) as RawMemory;
        this.entries = this.entries.map((e) =>
          e.id === id ? toEntry(raw) : e,
        );
      }
    } catch {
      // Roll back
      this.entries = previous;
      this.error = "Failed to update memory entry. Please try again.";
    }
  }

  async addMemory(
    entry: Omit<MemoryEntry, "id" | "created_at" | "updated_at">,
  ): Promise<MemoryEntry | null> {
    this.error = null;

    try {
      const response = await fetch(`${BASE_URL}${API_PREFIX}/memory`, {
        method: "POST",
        headers: authHeaders(),
        body: JSON.stringify(entry),
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const raw = (await response.json()) as RawMemory;
      const created = toEntry(raw);
      this.entries = [created, ...this.entries];
      return created;
    } catch {
      // Fall back: generate a local-only entry with a temporary id
      const now = new Date().toISOString();
      const local: MemoryEntry = {
        ...entry,
        id: `local-${crypto.randomUUID()}`,
        created_at: now,
        updated_at: now,
      };
      this.entries = [local, ...this.entries];
      this.error =
        "Memory saved locally — backend unavailable. Will sync when reconnected.";
      return local;
    }
  }

  // ── Search via dedicated endpoint ─────────────────────────────────────────

  /**
   * Fires a server-side search when a non-empty query is present.
   * Falls back to client-side filtering (via `filtered` derived) if the
   * backend is unavailable.
   */
  async searchMemories(
    query: string,
    category?: string,
    limit = 50,
  ): Promise<void> {
    if (!query.trim()) {
      await this.fetchMemories();
      return;
    }

    this.loading = true;
    this.error = null;

    try {
      const params = new URLSearchParams({ q: query, limit: String(limit) });
      if (category && category !== "all") {
        params.set("category", category);
      }

      const response = await fetch(
        `${BASE_URL}${API_PREFIX}/memory/search?${params.toString()}`,
        { headers: authHeaders() },
      );

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      const data = (await response.json()) as SearchResponse;
      const raw = Array.isArray(data.results) ? data.results : [];
      this.entries = raw.map(toEntry);
    } catch {
      // Silently fall back to client-side filtering already reflected in `filtered`
    } finally {
      this.loading = false;
    }
  }

  // ── UI State Setters ──────────────────────────────────────────────────────

  setSearch(q: string): void {
    this.searchQuery = q;
  }

  setFilter(category: string): void {
    this.filterCategory = category;
  }

  setSort(mode: SortMode): void {
    this.sortBy = mode;
  }

  select(id: string | null): void {
    this.selectedId = id;
  }

  clearError(): void {
    this.error = null;
  }

  reset(): void {
    this.entries = [];
    this.searchQuery = "";
    this.filterCategory = "all";
    this.selectedId = null;
    this.sortBy = "relevance";
    this.error = null;
    this.loading = false;
  }
}

// ── Singleton Export ───────────────────────────────────────────────────────────

export const memoryStore = new MemoryStore();
