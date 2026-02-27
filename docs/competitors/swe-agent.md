# SWE-Agent

> Threat Level: **LOW** | 15K+ GitHub Stars | Python | MIT License

## Overview

Open-source agent by Princeton NLP Group. Transforms LLMs into autonomous software engineering agents for GitHub issue resolution. Self-evolving scaffold.

## Key Features

- Custom **Agent-Computer Interface (ACI)** for file browsing, editing, testing
- Repository navigation and code understanding
- **Live-SWE-agent**: self-evolving agent that improves its own scaffold at runtime
- **mini-SWE-agent**: 100-line agent achieving 65% on SWE-bench Verified

## Performance

Claude Opus 4.5 + Live-SWE-agent: **79.2% on SWE-bench Verified** (SOTA for open-source)

## Notable Pattern: Self-Evolving Scaffold

The Live-SWE-agent approach — where the agent modifies its own tools during execution — is a unique architectural insight worth studying. This is conceptually similar to our dynamic skill creation but applied to the agent's own infrastructure.

## What They Have That We Don't

| Feature | Priority | Notes |
|---------|----------|-------|
| 79.2% SWE-bench (SOTA) | HIGH | Benchmark credibility |
| Self-evolving scaffold | HIGH | Agent improves own tools at runtime |
| ACI (Agent-Computer Interface) | MEDIUM | Optimized file/code interaction |

## What We Have That They Don't

Everything — multi-agent, memory, learning, channels, providers, CLI, hooks, budget, scheduling, sandboxing, Signal Theory. This is a research tool, not a product.

## Sources

- [GitHub](https://github.com/SWE-agent)
- [Paper](https://arxiv.org/abs/2405.15793)
- [Live-SWE-agent Paper](https://arxiv.org/abs/2511.13646)
