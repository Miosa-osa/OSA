# Competitive Intelligence

> Last updated: 2026-02-27

## Landscape

OSA operates at the intersection of **personal AI agent**, **CLI coding agent**, and **multi-agent framework**. No single competitor covers all three. This is our moat.

## Competitors by Category

### Personal AI Agents (messaging-first)
| Tool | Stars | Stack | Threat Level |
|------|-------|-------|-------------|
| [OpenClaw](openclaw.md) | 195K+ | Node.js/TS | **HIGH** — largest community, most channels |
| [NanoClaw](nanoclaw.md) | ~2K | Node.js/TS | LOW — minimal, Claude-only |

### CLI Coding Agents (developer-first)
| Tool | Stars | Stack | Threat Level |
|------|-------|-------|-------------|
| [Aider](aider.md) | 30K+ | Python | **HIGH** — SOTA SWE-bench, mature |
| [Codex CLI](codex-cli.md) | 25K+ | Rust | **MEDIUM** — OpenAI-only, new |
| [Goose](goose.md) | 15K+ | Rust | **MEDIUM** — MCP ecosystem, Block backing |

### IDE Agents (editor-integrated)
| Tool | Stars | Stack | Threat Level |
|------|-------|-------|-------------|
| [Cursor](cursor.md) | N/A (closed) | TS/Electron | **HIGH** — best UX, parallel agents |
| [Cline](cline.md) | 40K+ | TS/VS Code | **MEDIUM** — 5M users, browser automation |
| [Continue.dev](continue.md) | 25K+ | TS | LOW — model-agnostic but no agents |
| [Amp](amp.md) | N/A (closed) | TS | LOW — newer, team-focused |

### Agent Platforms (research/enterprise)
| Tool | Stars | Stack | Threat Level |
|------|-------|-------|-------------|
| [OpenHands](openhands.md) | 50K+ | Python | LOW — research-grade |
| [SWE-Agent](swe-agent.md) | 15K+ | Python | LOW — research-only |
| [Devin](devin.md) | N/A (closed) | Proprietary | LOW — $500/mo, cloud-only |

### Dormant / Niche
| Tool | Stars | Stack | Threat Level |
|------|-------|-------|-------------|
| [Mentat](mentat.md) | 3K | Python | NONE — maintenance mode |
| [Devon](devon.md) | 2K | Python | NONE — development stalled |
| [AutoCodeRover](autocoderover.md) | 3K | Python | NONE — academic only |

## Quick Feature Matrix

See [feature-matrix.md](feature-matrix.md) for the full side-by-side comparison.

## Our Position

```
                    PERSONAL AGENT
                         │
                    OpenClaw ★
                    NanoClaw
                         │
         ┌───────────────┼───────────────┐
         │               │               │
    CLI AGENT      ★ OSA ★        IDE AGENT
    Aider              (HERE)       Cursor
    Codex CLI                       Cline
    Goose                          Continue
         │               │               │
         └───────────────┼───────────────┘
                         │
                   AGENT PLATFORM
                    OpenHands
                    SWE-Agent
                      Devin
```

OSA is the **only tool** that sits at the center — combining multi-agent swarm orchestration, persistent learning, CLI coding agent capabilities, 18-provider LLM support, 12+ messaging channels, and local-first architecture on Elixir/OTP.
