// src/lib/stores/palette.svelte.ts
// Command Palette store — Svelte 5 class with $state/$derived runes.
// Manages open state, fuzzy search, grouped results, and recent history.

import { BASE_URL, API_PREFIX } from "$lib/api/client";

// ── Types ──────────────────────────────────────────────────────────────────────

export type CommandCategory =
  | "navigation"
  | "actions"
  | "commands"
  | "recent"
  | "search";

export interface PaletteCommand {
  id: string;
  name: string;
  description?: string;
  shortcut?: string;
  icon?: string;
  /** Badge label shown on search results (e.g. "Agent", "Task", "Project") */
  searchBadge?: string;
  category: CommandCategory;
  /** Called when the command is executed */
  action: () => void | Promise<void>;
}

interface ApiCommand {
  name: string;
  description?: string;
  usage?: string;
}

// ── Search source types ─────────────────────────────────────────────────────────

export interface SearchSource {
  type: string;
  icon: string;
  items: () => Array<{
    id: string | number;
    name: string;
    description?: string;
  }>;
  action: (item: { id: string | number; name: string }) => void;
}

// ── Fuzzy Match ────────────────────────────────────────────────────────────────

/**
 * Score-based fuzzy match.
 * Returns null if no match, otherwise a score (higher = better match).
 * Tiers: start-of-word match > anywhere match
 */
function fuzzyScore(text: string, query: string): number | null {
  if (!query) return 0;

  const t = text.toLowerCase();
  const q = query.toLowerCase();

  // Exact prefix match — highest score
  if (t.startsWith(q)) return 100;

  // Word-start match (e.g. "ns" matches "New Session")
  const words = t.split(/[\s_\-/]+/);
  const wordStarts = words.map((w) => w[0]).join("");
  if (wordStarts.startsWith(q)) return 80;

  // All query chars appear in order (subsequence)
  let qi = 0;
  for (let i = 0; i < t.length && qi < q.length; i++) {
    if (t[i] === q[qi]) qi++;
  }
  if (qi === q.length) {
    // Score by how compact the match is
    return Math.max(1, 60 - (t.length - q.length));
  }

  return null;
}

export interface GroupedResults {
  recent: PaletteCommand[];
  navigation: PaletteCommand[];
  actions: PaletteCommand[];
  commands: PaletteCommand[];
  search: PaletteCommand[];
}

// ── PaletteStore Class ─────────────────────────────────────────────────────────

const RECENT_STORAGE_KEY = "osa-palette-recent";
const MAX_RECENT = 5;
const MAX_VISIBLE = 14;
const SEARCH_MIN_CHARS = 3;

class PaletteStore {
  isOpen = $state(false);
  query = $state("");
  selectedIndex = $state(0);
  commands = $state<PaletteCommand[]>([]);
  recentIds = $state<string[]>([]);
  private searchSources = $state<SearchSource[]>([]);

  // ── Derived ───────────────────────────────────────────────────────────────────

  /** All commands flattened in display order for keyboard navigation */
  flatFiltered = $derived.by(() => {
    const grouped = this.grouped;
    return [
      ...grouped.recent,
      ...grouped.navigation,
      ...grouped.actions,
      ...grouped.commands,
      ...grouped.search,
    ].slice(0, MAX_VISIBLE);
  });

  grouped = $derived.by((): GroupedResults => {
    const q = this.query.trim();

    const score = (cmd: PaletteCommand): number | null =>
      fuzzyScore(`${cmd.name} ${cmd.description ?? ""}`, q);

    const matches = (cmd: PaletteCommand): boolean => score(cmd) !== null;

    const sorted = (cmds: PaletteCommand[]): PaletteCommand[] => {
      if (!q) return cmds;
      return cmds
        .map((cmd) => ({ cmd, s: score(cmd) ?? -1 }))
        .filter(({ s }) => s >= 0)
        .sort((a, b) => b.s - a.s)
        .map(({ cmd }) => cmd);
    };

    const byCategory = (cat: CommandCategory) =>
      this.commands.filter((c) => c.category === cat);

    // Recent: resolved from IDs, preserving order
    const recentCmds = this.recentIds
      .map((id) => this.commands.find((c) => c.id === id))
      .filter((c): c is PaletteCommand => c !== undefined)
      .filter((c) => !q || matches(c));

    // Search results: only when query is 3+ chars
    let searchResults: PaletteCommand[] = [];
    if (q.length >= SEARCH_MIN_CHARS) {
      for (const source of this.searchSources) {
        const items = source.items();
        for (const item of items) {
          const s = fuzzyScore(`${item.name} ${item.description ?? ""}`, q);
          if (s !== null && s > 0) {
            searchResults.push({
              id: `search-${source.type}-${item.id}`,
              name: item.name,
              description: item.description,
              icon: source.icon,
              searchBadge: source.type,
              category: "search",
              action: () => source.action(item),
            });
          }
        }
      }
      // Sort by score descending
      searchResults = searchResults
        .map((cmd) => ({
          cmd,
          s: fuzzyScore(`${cmd.name} ${cmd.description ?? ""}`, q) ?? 0,
        }))
        .sort((a, b) => b.s - a.s)
        .map(({ cmd }) => cmd)
        .slice(0, 6);
    }

    return {
      recent: recentCmds,
      navigation: sorted(byCategory("navigation")),
      actions: sorted(byCategory("actions")),
      commands: sorted(byCategory("commands")),
      search: searchResults,
    };
  });

  totalVisible = $derived(this.flatFiltered.length);

  // ── Lifecycle ─────────────────────────────────────────────────────────────────

  constructor() {
    // Restore recent from localStorage (browser-only)
    if (typeof window !== "undefined") {
      try {
        const stored = localStorage.getItem(RECENT_STORAGE_KEY);
        if (stored) this.recentIds = JSON.parse(stored) as string[];
      } catch {
        // Non-fatal
      }
    }
  }

  // ── Open / Close ──────────────────────────────────────────────────────────────

  open(): void {
    this.isOpen = true;
    this.query = "";
    this.selectedIndex = 0;
    // Fetch API commands each time the palette opens (cheap, keeps list fresh)
    void this.fetchCommands();
  }

  close(): void {
    this.isOpen = false;
    this.query = "";
    this.selectedIndex = 0;
  }

  toggle(): void {
    if (this.isOpen) {
      this.close();
    } else {
      this.open();
    }
  }

  // ── Navigation ────────────────────────────────────────────────────────────────

  moveUp(): void {
    if (this.totalVisible === 0) return;
    this.selectedIndex =
      (this.selectedIndex - 1 + this.totalVisible) % this.totalVisible;
  }

  moveDown(): void {
    if (this.totalVisible === 0) return;
    this.selectedIndex = (this.selectedIndex + 1) % this.totalVisible;
  }

  setQuery(q: string): void {
    this.query = q;
    this.selectedIndex = 0;
  }

  // ── Execute ───────────────────────────────────────────────────────────────────

  async execute(cmd: PaletteCommand): Promise<void> {
    this.addToRecent(cmd.id);
    this.close();
    await cmd.action();
  }

  async executeSelected(): Promise<void> {
    const cmd = this.flatFiltered[this.selectedIndex];
    if (cmd) await this.execute(cmd);
  }

  // ── Recent ────────────────────────────────────────────────────────────────────

  private addToRecent(id: string): void {
    const next = [id, ...this.recentIds.filter((r) => r !== id)].slice(
      0,
      MAX_RECENT,
    );
    this.recentIds = next;
    if (typeof window !== "undefined") {
      try {
        localStorage.setItem(RECENT_STORAGE_KEY, JSON.stringify(next));
      } catch {
        // Non-fatal
      }
    }
  }

  // ── Search Sources ─────────────────────────────────────────────────────────────

  /**
   * Registers live data sources for the search section.
   * Each source provides a reactive getter for its items.
   * Call from +layout.svelte after stores are available.
   */
  registerSearchSources(sources: SearchSource[]): void {
    this.searchSources = sources;
  }

  // ── Register Built-in Commands ────────────────────────────────────────────────

  /**
   * Registers the static navigation and action commands.
   * Call once after the goto function and store references are available.
   */
  registerBuiltins(
    goto: (path: string) => void,
    actions: {
      newSession: () => void;
      clearChat: () => void;
      toggleYolo: () => void;
      restartBackend: () => void;
      newIssue?: () => void;
      newProject?: () => void;
      refreshAll?: () => void;
    },
  ): void {
    const navCommands: PaletteCommand[] = [
      {
        id: "nav-dashboard",
        name: "Dashboard",
        description: "Go to the dashboard",
        shortcut: "⌘1",
        icon: "dashboard",
        category: "navigation",
        action: () => goto("/app"),
      },
      {
        id: "nav-chat",
        name: "Chat",
        description: "Open the chat interface",
        shortcut: "⌘2",
        icon: "chat",
        category: "navigation",
        action: () => goto("/app/chat"),
      },
      {
        id: "nav-agents",
        name: "Agents",
        description: "Manage running agents",
        shortcut: "⌘3",
        icon: "agents",
        category: "navigation",
        action: () => goto("/app/agents"),
      },
      {
        id: "nav-tasks",
        name: "Tasks",
        description: "View orchestrator tasks",
        icon: "tasks",
        category: "navigation",
        action: () => goto("/app/tasks"),
      },
      {
        id: "nav-issues",
        name: "Issues",
        description: "Track issues and bugs",
        icon: "issues",
        category: "navigation",
        action: () => goto("/app/issues"),
      },
      {
        id: "nav-signals",
        name: "Signals",
        description: "Monitor signal events",
        icon: "signals",
        category: "navigation",
        action: () => goto("/app/signals"),
      },
      {
        id: "nav-skills",
        name: "Skills",
        description: "Browse agent skills",
        icon: "skills",
        category: "navigation",
        action: () => goto("/app/skills"),
      },
      {
        id: "nav-models",
        name: "Models",
        description: "Browse and activate models",
        shortcut: "⌘4",
        icon: "models",
        category: "navigation",
        action: () => goto("/app/models"),
      },
      {
        id: "nav-memory",
        name: "Memory",
        description: "View agent memory store",
        icon: "memory",
        category: "navigation",
        action: () => goto("/app/memory"),
      },
      {
        id: "nav-connectors",
        name: "Connectors",
        description: "Connect OSA to local services",
        icon: "link",
        category: "navigation",
        action: () => goto("/app/connectors"),
      },
      {
        id: "nav-terminal",
        name: "Terminal",
        description: "Open the built-in terminal",
        icon: "terminal",
        category: "navigation",
        action: () => goto("/app/terminal"),
      },
      {
        id: "nav-usage",
        name: "Usage",
        description: "View token and cost usage",
        icon: "usage",
        category: "navigation",
        action: () => goto("/app/usage"),
      },
      {
        id: "nav-projects",
        name: "Projects",
        description: "Manage your projects",
        icon: "projects",
        category: "navigation",
        action: () => goto("/app/projects"),
      },
      {
        id: "nav-approvals",
        name: "Approvals",
        description: "Review pending approvals",
        icon: "approvals",
        category: "navigation",
        action: () => goto("/app/approvals"),
      },
      {
        id: "nav-activity",
        name: "Activity",
        description: "View activity log",
        icon: "activity",
        category: "navigation",
        action: () => goto("/app/activity"),
      },
      {
        id: "nav-settings",
        name: "Settings",
        description: "Configure OSA preferences",
        shortcut: "⌘,",
        icon: "settings",
        category: "navigation",
        action: () => goto("/app/settings"),
      },
    ];

    const actionCommands: PaletteCommand[] = [
      {
        id: "action-new-session",
        name: "New Chat Session",
        description: "Start a fresh chat session",
        shortcut: "⌘N",
        icon: "plus",
        category: "actions",
        action: actions.newSession,
      },
      {
        id: "action-new-issue",
        name: "New Issue",
        description: "Create a new issue",
        icon: "issues",
        category: "actions",
        action: () => {
          if (actions.newIssue) {
            actions.newIssue();
          } else {
            goto("/app/issues?new=1");
          }
        },
      },
      {
        id: "action-new-project",
        name: "New Project",
        description: "Create a new project",
        icon: "projects",
        category: "actions",
        action: () => {
          if (actions.newProject) {
            actions.newProject();
          } else {
            goto("/app/projects?new=1");
          }
        },
      },
      {
        id: "action-refresh",
        name: "Refresh All",
        description: "Refresh current page data",
        icon: "refresh",
        category: "actions",
        action: () => {
          if (actions.refreshAll) {
            actions.refreshAll();
          } else if (typeof window !== "undefined") {
            window.dispatchEvent(new CustomEvent("osa:refresh"));
          }
        },
      },
      {
        id: "action-clear-chat",
        name: "Clear Chat",
        description: "Clear the current conversation",
        icon: "trash",
        category: "actions",
        action: actions.clearChat,
      },
      {
        id: "action-toggle-yolo",
        name: "Toggle YOLO Mode",
        description: "Auto-approve all tool calls",
        shortcut: "⌘Y",
        icon: "bolt",
        category: "actions",
        action: actions.toggleYolo,
      },
      {
        id: "action-restart-backend",
        name: "Restart Backend",
        description: "Restart the OSA backend service",
        icon: "refresh",
        category: "actions",
        action: actions.restartBackend,
      },
    ];

    // Merge with any existing API commands (preserve them)
    const apiCommands = this.commands.filter((c) => c.category === "commands");
    this.commands = [...navCommands, ...actionCommands, ...apiCommands];
  }

  // ── API Commands ──────────────────────────────────────────────────────────────

  async fetchCommands(): Promise<void> {
    try {
      const res = await fetch(`${BASE_URL}${API_PREFIX}/commands`, {
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return;

      const data = (await res.json()) as
        | ApiCommand[]
        | { commands: ApiCommand[] };
      const raw: ApiCommand[] = Array.isArray(data)
        ? data
        : (data.commands ?? []);

      const apiCmds: PaletteCommand[] = raw.map((cmd) => ({
        id: `cmd-${cmd.name}`,
        name: cmd.name,
        description: cmd.description ?? cmd.usage,
        icon: "/",
        category: "commands" as CommandCategory,
        action: () => {
          // Slash commands are inserted into the chat input via a custom event
          if (typeof window !== "undefined") {
            window.dispatchEvent(
              new CustomEvent("osa:insert-command", {
                detail: { command: cmd.name },
              }),
            );
          }
        },
      }));

      // Preserve navigation + action builtins, replace API commands
      const builtins = this.commands.filter(
        (c) => c.category === "navigation" || c.category === "actions",
      );
      this.commands = [...builtins, ...apiCmds];
    } catch {
      // Backend may be offline — silently skip
    }
  }
}

// ── Singleton Export ───────────────────────────────────────────────────────────

export const paletteStore = new PaletteStore();
