# NanoClaw

> Threat Level: **LOW** | ~2K GitHub Stars | TypeScript | MIT License

## Overview

Minimalist, security-first alternative to OpenClaw. Created by Gavriel Cohen (ex-Wix). ~500 lines core, 15 source files. Built on Anthropic's Claude Agent SDK. Real container isolation (Apple Container on macOS, Docker on Linux).

## Key Features

- Single Node.js process
- **Container isolation** — agents can only access explicitly mounted directories
- WhatsApp integration, memory, scheduled jobs
- Agent Swarms (teams of agents collaborating in chat)
- Entire codebase auditable in ~8 minutes

## What They Have That We Don't

| Feature | Priority | Notes |
|---------|----------|-------|
| Apple Container isolation (macOS native) | LOW | Nice but niche |
| 500-line auditable codebase | — | Philosophy, not feature |

## What We Have That They Don't

Everything except Apple Container. Limited to Claude models, small ecosystem, fewer channels.

## Assessment

Interesting philosophy (security-first, minimal) but not a competitor at scale. Claude-only is a dealbreaker for provider-agnostic users.

## Sources

- [GitHub](https://github.com/qwibitai/nanoclaw)
- [The New Stack](https://thenewstack.io/nanoclaw-minimalist-ai-agents/)
- [Website](https://nanoclaw.dev/)
