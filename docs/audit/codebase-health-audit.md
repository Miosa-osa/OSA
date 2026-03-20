# OSA Codebase Health Audit — 2026-03-13

## Scope
Full codebase audit: duplicate files, dead code, circular references, shim catalog.

## Phase 1: Trash File Removal (COMPLETED)

**12 items deleted** — all macOS Finder duplicates:
- 10 duplicate files (` 2` suffix, byte-identical to originals)
- 2 duplicate directories (`app 2/`, `onboarding 2/` — older snapshots)

Files removed:
- `desktop/src/routes/app/activity/+page 2.svelte`
- `desktop/src/routes/app/connectors/+page 2.svelte`
- `desktop/src/routes/app/memory/+page 2.svelte`
- `desktop/src/routes/app/tasks/+page 2.svelte`
- `desktop/src/routes/app/usage/+page 2.svelte`
- `desktop/src/routes/app 2/` (entire directory)
- `desktop/src/routes/onboarding 2/` (entire directory)
- `priv/go/tui-v2/osagent 2`
- `test/agent/debate_test 2.exs`
- `test/agent/health_tracker_test 2.exs`
- `test/agent/skill_evolution_test 2.exs`
- `test/commands_duplicate_key_test 2.exs`

## Phase 2: Circular References & Dead Code

### P0 — Classifier Circular Delegation (FIXED)

**Bug:** `Events.Classifier` <-> `MiosaSignal.Classifier` formed an infinite mutual recursion loop. Neither contained real logic — both were pure `defdelegate` pointing at each other.

**Root cause:** When `miosa_signal` was extracted as a package, the shim was written to delegate back to `Events.Classifier`, but `Events.Classifier` had already been rewritten to delegate forward to `MiosaSignal.Classifier`.

**Fix:** `Events.Classifier` now delegates to the real implementation at `Signal.Classifier` (LLM + deterministic fallback). The `MiosaSignal.Classifier` shim continues to point at `Events.Classifier` (one-way, no cycle).

**Risk mitigated:** Any call to either classifier would have caused a stack overflow. `Events.Bus` aliases `Events.Classifier`.

### Shim Catalog (28 modules in `lib/miosa/shims.ex`)

| Shim Module | Target | Type |
|---|---|---|
| `MiosaTools.Behaviour` | — | Behaviour definition |
| `MiosaLLM.HealthChecker` | `OSA.Providers.HealthChecker` | Pass-through |
| `MiosaProviders.Registry` | `OSA.Providers.Registry` | Pass-through |
| `MiosaProviders.Ollama` | `OSA.Providers.Ollama` | Pass-through |
| `MiosaSignal.Event` | `OSA.Events.Event` | Pass-through + struct |
| `MiosaSignal.CloudEvent` | `OSA.Protocol.CloudEvent` | Pass-through + struct |
| `MiosaSignal.Classifier` | `OSA.Events.Classifier` | Pass-through (was circular, now fixed) |
| `MiosaSignal.MessageClassifier` | — | Self-contained logic |
| `MiosaSignal.FailureModes` | `OSA.Events.FailureModes` | Pass-through |
| `MiosaMemory.Emitter` | — | Behaviour definition |
| `MiosaMemory.Cortex` | — | Stub GenServer (loop-breaker) |
| `MiosaMemory.Episodic` | `OSA.Agent.Memory.Episodic` | Pass-through |
| `MiosaMemory.Injector` | `OSA.Agent.Memory.Injector` | Pass-through |
| `MiosaMemory.Taxonomy` | `OSA.Agent.Memory.Taxonomy` | Pass-through |
| `MiosaMemory.Learning` | `OSA.Agent.Learning` | Pass-through |
| `MiosaMemory.Parser` | — | Self-contained logic |
| `MiosaMemory.Index` | `MiosaMemory.Parser` | Pass-through |
| `MiosaBudget.Emitter` | — | Behaviour definition |
| `MiosaBudget.Budget` | — | Full implementation (canonical) |
| `MiosaBudget.Treasury` | — | Stub GenServer (no callers) |
| `MiosaKnowledge.Registry` | — | Stub (not_implemented) |
| `MiosaKnowledge.Backend.ETS` | — | Stub |
| `MiosaKnowledge.Backend.Mnesia` | — | Stub |
| `MiosaKnowledge.Context` | — | Stub |
| `MiosaKnowledge.Reasoner` | — | Stub |
| `MiosaKnowledge.Store` | — | Stub |
| `MiosaKnowledge` | — | Stub |
| `MiosaSignal` | — | Self-contained logic (Signal struct) |

### Dead Code Candidates

1. **`MiosaKnowledge.*` (7 stubs)** — Real `miosa_knowledge` package wires through `tools/builtins/knowledge.ex`, bypassing these shims. Safe to remove when confirmed.
2. **`MiosaBudget.Treasury`** — No callers found. Placeholder for future use.
3. **`MiosaMemory.Cortex`** — Stub GenServer with empty returns. Real work in `OSA.Agent.Cortex`.

### xref Statistics
- 367 tracked files, 856 runtime edges
- 7 cycles detected (1 critical — fixed, 6 structural/compile-time)
- No unreachable functions reported by `mix xref unreachable`

## Recommendations for Future Work

1. **Shim consolidation** — When MIOSA packages are fully extracted, remove shims and update all callers
2. **MiosaKnowledge stubs** — Verify bypass and remove dead stubs
3. **Treasury audit** — Decide if Treasury is a planned feature or dead weight
4. **Compile cycles** — 6 remaining cycles are structural (behaviour <-> implementation), not runtime bugs
