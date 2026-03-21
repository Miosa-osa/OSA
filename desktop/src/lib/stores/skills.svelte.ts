import { skills as skillsApi } from "$lib/api/client";
import type { Skill, SkillCategory, SkillCategoryCount } from "$lib/api/types";
import { toastStore } from "$lib/stores/toasts.svelte";

const ALL_CATEGORIES: SkillCategory[] = [
  "core",
  "automation",
  "reasoning",
  "workflow",
  "security",
  "agent",
  "utility",
];

class SkillsStore {
  skills = $state<Skill[]>([]);
  categories = $state<SkillCategoryCount[]>([]);
  loading = $state(false);
  error = $state<string | null>(null);
  searchQuery = $state("");
  activeCategory = $state<string>("all");

  filtered = $derived.by((): Skill[] => {
    let result = this.skills;

    if (this.activeCategory !== "all") {
      result = result.filter((s) => s.category === this.activeCategory);
    }

    const q = this.searchQuery.toLowerCase().trim();
    if (q) {
      result = result.filter(
        (s) =>
          s.name.toLowerCase().includes(q) ||
          s.description.toLowerCase().includes(q) ||
          s.triggers.some((t) => t.toLowerCase().includes(q)),
      );
    }

    return result;
  });

  enabledCount = $derived(this.skills.filter((s) => s.enabled).length);
  totalCount = $derived(this.skills.length);

  allCategories = $derived.by(
    (): { name: string; label: string; count: number }[] => {
      const counts = new Map<string, number>();
      for (const s of this.skills) {
        counts.set(s.category, (counts.get(s.category) || 0) + 1);
      }

      const items = ALL_CATEGORIES.filter((c) => counts.has(c)).map((c) => ({
        name: c,
        label: c.charAt(0).toUpperCase() + c.slice(1),
        count: counts.get(c) || 0,
      }));

      return [
        { name: "all", label: "All", count: this.skills.length },
        ...items,
      ];
    },
  );

  async fetchSkills() {
    this.loading = true;
    this.error = null;
    try {
      this.skills = await skillsApi.list();
    } catch (e) {
      this.error = e instanceof Error ? e.message : "Failed to load skills";
      if (
        e instanceof TypeError ||
        (e instanceof Error && e.message === "Failed to fetch")
      ) {
        toastStore.warning("Backend offline — some features unavailable");
      } else {
        toastStore.error("Failed to load skills");
      }
    } finally {
      this.loading = false;
    }
  }

  async toggle(id: string) {
    const idx = this.skills.findIndex((s) => s.id === id);
    if (idx === -1) return;

    // Optimistic update
    const prev = this.skills[idx].enabled;
    this.skills[idx] = { ...this.skills[idx], enabled: !prev };

    try {
      const result = await skillsApi.toggle(id);
      this.skills[idx] = { ...this.skills[idx], enabled: result.enabled };
    } catch {
      this.skills[idx] = { ...this.skills[idx], enabled: prev };
      toastStore.error("Failed to toggle skill");
    }
  }

  async bulkEnable(ids: string[]) {
    this.skills = this.skills.map((s) =>
      ids.includes(s.id) ? { ...s, enabled: true } : s,
    );
    try {
      await skillsApi.bulkEnable(ids);
    } catch {
      await this.fetchSkills();
    }
  }

  async bulkDisable(ids: string[]) {
    this.skills = this.skills.map((s) =>
      ids.includes(s.id) ? { ...s, enabled: false } : s,
    );
    try {
      await skillsApi.bulkDisable(ids);
    } catch {
      await this.fetchSkills();
    }
  }

  setSearch(query: string) {
    this.searchQuery = query;
  }

  setCategory(category: string) {
    this.activeCategory = category;
  }
}

export const skillsStore = new SkillsStore();
