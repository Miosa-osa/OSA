# Goose (by Block)

> Threat Level: **MEDIUM** | 15K+ GitHub Stars | Rust | Apache 2.0

## Overview

Open-source AI agent framework by Block (Jack Dorsey's company). Runs locally, MCP-first extensibility. 60% of Block workforce uses it weekly. CLI + desktop app.

## Key Features

- Build, write/execute code, debug, orchestrate workflows
- **First-class MCP support** (1,700+ extensions)
- CLI + desktop app (not IDE-locked)
- Named sessions and chat history
- **Subagents** for parallel task execution
- **Recipes**: structured workflow definitions
- **Skills** for custom context injection
- Local-first, private data

## What They Have That We Don't

| Feature | Priority | Notes |
|---------|----------|-------|
| 1,700+ MCP extensions | HIGH | Massive tool ecosystem |
| Rust performance | LOW | We have BEAM concurrency instead |
| Desktop app (GUI) | MEDIUM | Visual interface option |
| Recipe system | MEDIUM | Declarative workflow definitions |
| Block production adoption (60% workforce) | — | Social proof |

## What We Have That They Don't

| Feature | Our Advantage |
|---------|---------------|
| Full multi-agent orchestration (waves, roles) | They have basic subagents only |
| Persistent memory & learning (SICA) | No memory system |
| Signal Theory | No message intelligence |
| 12+ messaging channels | CLI + desktop only |
| 10 swarm presets | No swarm patterns |
| OTP fault tolerance | Rust is fast but no process isolation |
| Hook pipeline | No middleware |
| Budget/cost management | No cost tracking |
| 18 LLM providers | ~6 providers |
| Scheduling (heartbeat/cron/triggers) | No autonomous behavior |
| Chinese provider support | None |

## Sources

- [GitHub](https://github.com/block/goose)
- [Website](https://block.github.io/goose/)
- [Block Announcement](https://block.xyz/inside/block-open-source-introduces-codename-goose)
