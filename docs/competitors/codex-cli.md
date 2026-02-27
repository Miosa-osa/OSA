# Codex CLI (by OpenAI)

> Threat Level: **MEDIUM** | 25K+ GitHub Stars | Rust | Apache 2.0

## Overview

OpenAI's open-source terminal coding agent. Built in Rust. Uses GPT-5.2-Codex model. Three approval modes.

## Key Features

- Local terminal execution (read, change, run code)
- **Three approval modes**: read-only, auto (workspace-scoped), full access
- **Multi-agent collaboration** (experimental, via config.toml)
- Code review by separate Codex agent
- Web search integration
- MCP support
- Image attachment (screenshots, wireframes, diagrams)
- **Voice transcription** (hold spacebar)
- To-do list progress tracking
- **Codex Jobs** (future): cloud-based automation on triggers

## What They Have That We Don't

| Feature | Priority | Notes |
|---------|----------|-------|
| Approval modes (read-only/auto/full) | MEDIUM | Granular permission control |
| Voice input (spacebar) | LOW | Quick voice commands |
| Image context (screenshots) | MEDIUM | Visual debugging |
| To-do list tracking | LOW | Built-in task management UX |

## What We Have That They Don't

| Feature | Our Advantage |
|---------|---------------|
| 18 LLM providers | OpenAI models ONLY — locked in |
| Multi-agent orchestration (production) | Their multi-agent is experimental |
| Persistent memory & learning | No memory |
| Signal Theory | Nothing |
| 12+ messaging channels | Terminal-only |
| Swarm patterns (10 presets) | No swarms |
| OTP fault tolerance | No process isolation |
| Hook pipeline | No middleware |
| Budget/cost management | No cost tracking |
| Scheduling & automation | No autonomous behavior |
| Open provider ecosystem | Vendor lock-in |

## Assessment

Strong entry from OpenAI but crippled by vendor lock-in (OpenAI models only). The multi-agent is experimental. No memory, no learning, no channels. Our multi-provider, multi-agent, multi-channel architecture makes this a non-threat long-term.

## Sources

- [GitHub](https://github.com/openai/codex)
- [Docs](https://developers.openai.com/codex/cli/)
