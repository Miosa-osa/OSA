/**
 * Settings store — mirrors the Elixir backend settings at localhost:9089.
 *
 * GET  /api/v1/settings  → returns Settings
 * PATCH /api/v1/settings → body: Partial<Settings>, returns Settings
 *
 * The store fetches on init and exposes a save() method for partial updates.
 * Errors are surfaced via toastStore.
 */
import { writable } from "svelte/store";
import { settings as settingsApi } from "$lib/api/client";
import { toastStore } from "$lib/stores/toasts.svelte";
import type { Settings } from "$lib/api/types";

// ── Public types ───────────────────────────────────────────────────────────────

export type { Settings };

export interface SettingsState {
  /** Whether the initial fetch has completed (success or error). */
  initialized: boolean;
  /** The live settings values from the backend, or null before first fetch. */
  data: Settings | null;
  /** Whether a fetch or save is in flight. */
  loading: boolean;
  /** Last error message, or null. */
  error: string | null;
}

// ── Store factory ──────────────────────────────────────────────────────────────

function createSettingsStore() {
  const { subscribe, set, update } = writable<SettingsState>({
    initialized: false,
    data: null,
    loading: false,
    error: null,
  });

  /**
   * Fetch current settings from GET /api/v1/settings.
   * Called automatically on init; can also be called to force a refresh.
   */
  async function load(): Promise<void> {
    update((s) => ({ ...s, loading: true, error: null }));
    try {
      const data = await settingsApi.get();
      update((s) => ({ ...s, data, loading: false, initialized: true }));
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to load settings";
      const isOffline =
        err instanceof TypeError ||
        (err instanceof Error && err.message === "Failed to fetch");

      update((s) => ({
        ...s,
        loading: false,
        initialized: true,
        error: message,
      }));

      if (isOffline) {
        toastStore.warning("Backend offline — settings unavailable");
      } else {
        toastStore.error("Failed to load settings", message);
      }
    }
  }

  /**
   * Save a partial settings update via PATCH /api/v1/settings.
   * Optimistically writes the patch to the store and rolls back on error.
   */
  async function save(patch: Partial<Settings>): Promise<void> {
    // Capture current state for rollback
    let previous: Settings | null = null;
    update((s) => {
      previous = s.data;
      return {
        ...s,
        loading: true,
        error: null,
        data: s.data ? { ...s.data, ...patch } : s.data,
      };
    });

    try {
      const updated = await settingsApi.update(patch);
      update((s) => ({ ...s, data: updated, loading: false }));
      toastStore.success("Settings saved");
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to save settings";
      // Roll back optimistic update
      update((s) => ({ ...s, data: previous, loading: false, error: message }));
      toastStore.error("Failed to save settings", message);
    }
  }

  /**
   * Reset store to initial empty state (e.g. on logout).
   */
  function reset(): void {
    set({ initialized: false, data: null, loading: false, error: null });
  }

  // Fetch on creation so any subscriber immediately gets live data.
  void load();

  return {
    subscribe,
    load,
    save,
    reset,
  };
}

export const settingsStore = createSettingsStore();
