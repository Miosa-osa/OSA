# OpenClaw

> Threat Level: **HIGH** | 195K+ GitHub Stars | Node.js/TS | MIT License

## Overview

Open-source autonomous personal AI agent created by Peter Steinberger (PSPDFKit founder). Originally "Clawdbot" (Nov 2025), renamed to Moltbot, then OpenClaw (Jan 2026). Messaging-first UX — WhatsApp/Telegram/Discord as primary interface, not CLI/IDE. Steinberger joining OpenAI; project moving to open-source foundation.

## Architecture

```
User ──► Messaging Platform ──► Gateway Daemon (WebSocket hub-and-spoke)
                                    │
                              Agent Runtime
                              ├── Context Assembly (history + memory)
                              ├── LLM Invocation
                              ├── Tool Execution
                              └── State Persistence
```

- **Single Node.js process** — no native clustering, in-memory command queue
- **Lobster** — built-in deterministic workflow engine (typed JSON data flow)

## Key Features

| Category | Details |
|----------|---------|
| Channels | 50+ (WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Teams, Google Chat, Matrix, Zalo...) |
| LLM Providers | 15+ (Anthropic, OpenAI, Gemini, Ollama, DeepSeek, Groq, Mistral, OpenRouter, GitHub Copilot, HuggingFace, vLLM, LMStudio) |
| Skills | 2,857+ on ClawHub marketplace, ~49 built-in. Markdown + YAML frontmatter format |
| Memory | Plain Markdown files + SQLite-backed hybrid RAG (vector 0.7 / text 0.3, MMR, temporal decay) |
| CLI | 150+ commands, `--json` output, `openclaw doctor`, onboarding wizard |
| Heartbeat | 30-min scheduled agent wake-ups for proactive behavior |
| Security | Docker sandbox (opt-in), tool policy resolution, mandatory gateway auth (post-CVE-2026-25253) |
| Voice | Full TTS + STT + wake word + talk mode |
| Browser | Chrome CDP + Playwright automation |
| Mobile | iOS + Android + macOS native nodes |
| UI | Control UI web dashboard + WebChat + A2UI protocol |

## What They Have That We Don't

| Feature | Priority | Roadmap Phase |
|---------|----------|---------------|
| 50+ messaging channels (vs our 12) | MEDIUM | Phase 3 |
| Voice/audio (TTS, STT, wake word) | MEDIUM | Phase 4 |
| Browser automation (CDP, Playwright) | HIGH | Phase 2 |
| Web dashboard / Control UI | MEDIUM | Phase 3 |
| Mobile nodes (iOS/Android/macOS) | LOW | Phase 5 |
| IDE integration (ACP protocol) | HIGH | Phase 2 |
| Skill marketplace (ClawHub, 2857+ skills) | MEDIUM | Phase 4 |
| Device pairing (QR + challenge-response) | LOW | Phase 5 |
| Rich TUI with navigation | MEDIUM | Phase 3 |
| Auto-reply / DND modes | LOW | Phase 4 |
| Presence system (online/offline/typing) | LOW | Phase 4 |
| Remote access (Tailscale + SSH tunnels) | LOW | Phase 5 |
| Vector embeddings in memory search | HIGH | Phase 1 |

## What We Have That They Don't

| Feature | Our Advantage |
|---------|---------------|
| OTP fault tolerance | Supervisor trees, process isolation, hot code reload. They crash = full restart |
| BEAM concurrency | 30+ simultaneous processes vs single event loop |
| Signal Theory (5-tuple classification) | Intelligent message classification and noise filtering. They have nothing |
| SICA learning engine | Self-improving pattern recognition. They have zero learning |
| Cortex knowledge synthesis | Cross-session topic tracking and bulletins. Nothing comparable |
| 3-zone context compaction | Progressive compression with importance weighting. They do basic truncation |
| Wave-based multi-agent orchestration | 9 roles, 5 waves, dependency tracking, 10 swarm presets. They have Lobster (basic) |
| Per-agent budget caps | Token cost governance per agent. They have no cost control |
| Tool gating by model capability | Prevents hallucinated tool calls from small models. They send tools to everything |
| VIGIL error taxonomy | Structured error recovery with auto-learning. They have basic try/catch |
| Dynamic skill creation at runtime | Agent creates new skills during execution. They require manual skill files |
| CloudEvents protocol | Standards-based event interop. They use custom webhooks |
| Request integrity (HMAC-SHA256 + nonce) | Beyond JWT. They stopped at JWT |
| Treasury governance | Financial controls with deposits/withdrawals/reservations. Nothing |
| Chinese provider support | Qwen, Zhipu, Moonshot, VolcEngine, Baichuan. They have zero |

## Vulnerabilities

- **CVE-2026-25253**: Critical unauthenticated RCE via WebSocket. Patched Feb 2026.
- **Skill trust model**: Cisco found data exfiltration in third-party skills. No vetting on marketplace.
- **No sandboxing by default**: Gateway runs on host with full filesystem/network access.
- **Single process**: No fault isolation. One bad skill crashes everything.

## Sources

- [GitHub](https://github.com/openclaw/openclaw)
- [Docs](https://docs.openclaw.ai)
- [Wikipedia](https://en.wikipedia.org/wiki/OpenClaw)
- [Architecture Deep Dive](https://ppaolo.substack.com/p/openclaw-system-architecture-overview)
- [CrowdStrike Security Analysis](https://www.crowdstrike.com/en-us/blog/what-security-teams-need-to-know-about-openclaw-ai-super-agent/)
- [Memory System (memsearch)](https://milvus.io/blog/we-extracted-openclaws-memory-system-and-opensourced-it-memsearch.md)
