# Foundation Core — OSA Documentation

> **OSA v1.0.010** — Optimal System Agent
> Elixir/OTP + Rust TUI + Tauri/SvelteKit. Signal Theory-based AI agent orchestration.
> 154,000 lines. 18 LLM providers. 12 chat channels. Runs locally. Apache 2.0.

---

## What You Are Looking At

OSA is a production AI agent system built on Elixir/OTP. It is the intelligence
layer of the [MIOSA](https://miosa.ai) platform and is also fully usable as a
standalone local agent.

The architecture solves a real problem: every existing agent framework processes
every message through the same pipeline regardless of complexity. OSA classifies
each input into a 5-tuple signal before routing — matching compute to complexity
automatically, at sub-millisecond speed, before the LLM is ever invoked.

This section documents the **foundation**: why OSA exists, the principles that
govern its design, where its boundaries lie, the dependency rules its modules
obey, and the vocabulary used throughout all other documentation.

---

## In This Section

| Document | What It Covers |
|---|---|
| [Purpose](overview/purpose.md) | The problem OSA solves, Signal Theory foundations, theoretical grounding |
| [Architecture Principles](overview/architecture-principles.md) | OTP design philosophy, event routing, storage patterns, context assembly |
| [System Boundaries](overview/system-boundaries.md) | What OSA is, what it is not, external dependencies, integration points |
| [Dependency Rules](overview/dependency-rules.md) | Layer ordering, supervision strategy, external package roles |
| [Glossary](overview/glossary.md) | Canonical definitions for all OSA-specific terms |

---

## Codebase at a Glance

```
Codebase Breakdown
─────────────────────────────────────────────────────────────────
Elixir/OTP   lib/                77,000 lines   Core agent, orchestration,
                                                providers, channels, tools,
                                                swarm, sandbox
Desktop      desktop/            27,000 lines   Command Center — Tauri 2 +
                                                SvelteKit 2 + Svelte 5
Rust TUI     priv/rust/tui/      20,000 lines   Terminal interface, SSE client,
                                                auth, rendering
Tests        test/               29,000 lines   ~2,000 tests across all modules
Go utilities priv/go/               900 lines   Tokenizer, git helper, sysmon
Config       config/                500 lines   Runtime, dev, test, prod
─────────────────────────────────────────────────────────────────
Total                           ~154,000 lines
```

---

## System Summary

### Signal Theory Classification

Every input is classified into a 5-tuple before routing:

```
S = (Mode, Genre, Type, Format, Weight)
```

| Dimension | Values |
|---|---|
| Mode | BUILD, EXECUTE, ANALYZE, MAINTAIN, ASSIST |
| Genre | DIRECT, INFORM, COMMIT, DECIDE, EXPRESS |
| Type | question, request, issue, scheduling, summary, report, general |
| Format | message, command, document, notification |
| Weight | 0.0 (trivial) to 1.0 (critical, multi-step) |

Weight drives tier selection:

| Weight Range | Tier | Examples |
|---|---|---|
| 0.00 – 0.35 | Utility | Haiku, GPT-3.5-turbo, 8B local models |
| 0.35 – 0.65 | Specialist | Sonnet, GPT-4o-mini, 70B local models |
| 0.65 – 1.00 | Elite | Opus, GPT-4o, Gemini 2.5 Pro |

### OTP Supervision Tree (top-level)

```
OptimalSystemAgent.Supervisor  (rest_for_one)
├── Platform.Repo              PostgreSQL — multi-tenant (conditional)
├── Supervisors.Infrastructure  (rest_for_one) — core registries, event bus, storage
├── Supervisors.Sessions        (one_for_one)  — channel adapters, agent loop processes
├── Supervisors.AgentServices   (one_for_one)  — memory, hooks, orchestrator, vault
├── Supervisors.Extensions      (one_for_one)  — sandbox, fleet, sidecars (opt-in)
├── Channels.Starter            Deferred channel boot
└── Bandit HTTP                 REST API — port 9089
```

### Key Numbers

| Metric | Count |
|---|---|
| Elixir modules | 287+ |
| LLM providers | 18 (3 tiers each) |
| Chat channels | 12 |
| Built-in tools | 34 |
| Slash commands | 91+ |
| Agent roles in roster | 31 named + 17 specialized |
| Tests | ~2,000 |
| Vault memory categories | 8 |
| Hook lifecycle events | 7 |
| Swarm collaboration patterns | 4 |

---

## Runtime Ports

| Port | Service |
|---|---|
| 9089 | Elixir backend — REST API + SSE + webhook receiver. The Tauri desktop app runs this as a sidecar and connects to it on startup. |
| 11434 | Ollama local inference (default, optional) |

---

## Quick Navigation

**New to OSA?** Start with [Purpose](overview/purpose.md) then
[System Boundaries](overview/system-boundaries.md).

**Building on OSA?** Read [Dependency Rules](overview/dependency-rules.md) and
the [Glossary](overview/glossary.md), then move to the
[backend docs](../backend/).

**Deploying OSA?** See [operations docs](../operations/).

**Contributing?** The [architecture docs](../architecture/) cover the
full supervision tree, data flow, Signal Theory spec, and ADRs.

---

## Full Documentation Index

```
docs/
├── foundation-core/        This section — why, what, boundaries, rules, glossary
├── getting-started/        Install, configuration, quickstart
├── architecture/           System design, Signal Theory, data flow, ADRs, SDK
├── backend/
│   ├── agent-loop/         Core reasoning engine — loop, context, strategies
│   ├── memory/             5-layer memory — JSONL, episodic, vault, knowledge graph
│   ├── orchestration/      Multi-agent — orchestrator, roster, swarm, fleet
│   ├── tools/              34 built-in tools, middleware pipeline, custom tools
│   ├── channels/           12 I/O adapters — CLI, HTTP, messaging platforms
│   ├── events/             goldrush event bus, protocol, telemetry
│   ├── platform/           Multi-tenant auth, tenants, AMQP, instances
│   ├── infrastructure/     Sandbox, MCP, sidecar, scheduler, security
│   └── providers/          18 LLM providers — config, circuit breaker, tier routing
├── frontend/               HTTP API reference, CLI command reference
├── features/               Recipes, skills, hooks, voice, proactive mode, tasks
├── operations/             Deployment, debugging, changelog
└── research/               Competitors, flows, roadmap (internal)
```

---

*Built by [Roberto H. Luna](https://github.com/robertohluna) and the MIOSA team.*
*Grounded in [Signal Theory](https://zenodo.org/records/18774174) (Luna, 2026).*
*Powered by the BEAM.*
