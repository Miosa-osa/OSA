# OpenHands (formerly OpenDevin)

> Threat Level: **LOW** | 50K+ GitHub Stars | Python | MIT License

## Overview

Open-source platform for AI software development agents. Academic + industry collaboration. Docker-sandboxed runtime. Hierarchical multi-agent with delegation.

## Key Features

- Docker-sandboxed runtime (bash + browser + IPython)
- **Agent Hub**: 10+ implemented agents (CodeAct as flagship)
- Hierarchical multi-agent with delegation primitives
- **15 evaluation benchmarks** built-in
- SDK: composable Python library for agents
- Cloud scaling: local to 1000s of agents
- Web UI for interaction

## Performance

SWE-bench Lite: 26% | HumanEvalFix: 79% | WebArena: 15% | GPQA: 53%

## What They Have That We Don't

| Feature | Priority | Notes |
|---------|----------|-------|
| 15 built-in evaluation benchmarks | MEDIUM | Self-assessment framework |
| Web UI | MEDIUM | Browser-based interaction |
| Agent Hub (10+ agents) | LOW | Pre-built agent library |
| Cloud scaling (1000s of agents) | LOW | Enterprise-scale orchestration |

## What We Have That They Don't

| Feature | Our Advantage |
|---------|---------------|
| OTP fault tolerance | Python has no process isolation |
| Persistent memory & learning (SICA) | No memory between sessions |
| Signal Theory | Nothing |
| 18 LLM providers | ~6 providers |
| 12+ messaging channels | Web UI only |
| Production-ready CLI | Research-oriented |
| Hook pipeline | No middleware |
| Budget/cost management | No cost tracking |
| Scheduling & automation | No autonomous behavior |

## Assessment

Strong academic project but research-grade, not production-ready. Lower SWE-bench than Aider. Their evaluation framework is worth studying. Not a direct competitor.

## Sources

- [GitHub](https://github.com/OpenHands/OpenHands)
- [Website](https://openhands.dev/)
- [Paper](https://arxiv.org/abs/2407.16741)
