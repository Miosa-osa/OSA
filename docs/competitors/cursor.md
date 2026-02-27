# Cursor

> Threat Level: **HIGH** | Proprietary | TS/Electron (VS Code fork) | $20-40/mo

## Overview

Commercial AI-first code editor by Anysphere. Not open-source. The most polished AI coding experience available. Rebuilt VS Code around AI as a first-class citizen.

## Key Features

- Full IDE with deep AI integration (not a plugin)
- Multi-line code completion with recent-change awareness
- Codebase-wide understanding and natural language querying
- **Cursor 2.0**: Own coding model (Composer), agent-centric interface
- **8 parallel agents** via git worktrees or remote machines
- **Plan Mode**: reads docs/rules, generates editable Markdown plan
- **Background Agents**: async task execution
- Built-in browser for UI verification
- Rules, Slash Commands, Hooks
- Model flexibility (OpenAI, Anthropic, Gemini, xAI)

## What They Have That We Don't

| Feature | Priority | Notes |
|---------|----------|-------|
| IDE integration (native) | HIGH | Full editor experience |
| Built-in browser for visual verification | MEDIUM | See UI changes in real-time |
| Background agents (cloud) | MEDIUM | Async task execution |
| Plan mode with collaborative refinement | MEDIUM | Editable plan before execution |
| Git worktree isolation per agent | HIGH | Clean parallel execution |

## What We Have That They Don't

| Feature | Our Advantage |
|---------|---------------|
| Open source | They are proprietary, closed |
| Self-hosting / local-first | They require cloud |
| 18 LLM providers | They support ~4 |
| Persistent memory & learning | No cross-session memory |
| 12+ messaging channels | IDE-only |
| Swarm patterns (10 presets) | Basic parallel agents |
| Signal Theory | No message intelligence |
| OTP fault tolerance | Electron crashes |
| Budget/cost management | Flat subscription |
| Custom skills & hooks | Limited extensibility |
| Scheduling (heartbeat/cron) | No autonomous behavior |

## Assessment

Cursor has the best UX in the space. But it's closed, expensive, and limited to the IDE paradigm. Our advantage: open-source, local-first, multi-channel, and architecturally superior (OTP vs Electron). The IDE integration gap is our biggest weakness against Cursor.

## Sources

- [Website](https://cursor.com/)
- [Features](https://cursor.com/features)
