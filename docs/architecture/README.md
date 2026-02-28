# Architecture

> Core design principles and system internals

## Guides

- [Signal Theory](signal-theory.md) — 5-tuple signal classification, noise filtering, communication intelligence
- [Memory & Learning](memory-and-learning.md) — 3-store memory, SICA learning cycle, VIGIL error taxonomy, context compaction
- [SDK Architecture](sdk.md) — Internal SDK structure and module organization

## System Overview

OSA is built on Elixir/OTP with 25+ supervised subsystems:

```
Application
├── Agent.Supervisor (orchestrator, loop, hooks, learning)
├── Provider.Registry (18 providers, tier routing)
├── Channel.Manager (12+ channels, auto-start)
├── Memory.Supervisor (episodic, semantic, procedural stores)
├── Swarm.Supervisor (patterns, presets, wave execution)
├── Tool.Supervisor (45+ tools, safety gating)
├── Context.Manager (3-zone compaction)
└── HTTP.Endpoint (REST API, webhooks)
```

## Key Design Decisions

- **OTP Supervision** — crash isolation, automatic restart, let-it-crash philosophy
- **Behaviour Callbacks** — providers and channels are pluggable via `@behaviour`
- **Tier-Aware Routing** — elite/specialist/utility maps to models automatically
- **Tool Gating** — small models get NO tools to prevent hallucination
- **Signal Theory** — every output classified by 5-tuple (Mode, Genre, Type, Format, Weight)
- **Parallel Tool Execution** — independent tool calls from a single LLM response execute concurrently via `Task.async_stream` (max 10, 60s timeout). Pre-tool hooks (security_check, spend_guard) run sync per-tool inside each task.
- **Doom Loop Detection** — if the same set of tools fails 3 consecutive iterations, the agent halts with an explanation instead of looping indefinitely. Tracked via `consecutive_failures` + `last_tool_signature` on the Loop state.
- **Destructive Git Protection** — `ShellPolicy` blocks `git push --force`, `git reset --hard`, `git clean -f`, `git checkout -- .`, `git branch -D`, and `--no-verify` flags. Safe operations (`git push`, `git commit`, `git checkout <branch>`) are allowed.
