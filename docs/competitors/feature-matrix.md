# Feature Matrix — OSA vs All Competitors

> Last updated: 2026-02-27

## Legend
- **Y** = Yes, fully implemented
- **P** = Partial / experimental
- **N** = Not available
- **—** = Not applicable

## Core Architecture

| Feature | OSA | OpenClaw | Aider | Cursor | Cline | Goose | Codex CLI | OpenHands |
|---------|-----|----------|-------|--------|-------|-------|-----------|-----------|
| Open Source | Y | Y (MIT) | Y (Apache) | N | Y (Apache) | Y (Apache) | Y (Apache) | Y (MIT) |
| Language | Elixir/OTP | Node.js/TS | Python | TS/Electron | TS | Rust | Rust | Python |
| Fault Tolerance | Y (OTP supervisors) | N | N | N | N | N | N | N |
| Hot Code Reload | Y | N | N | N | N | N | N | N |
| Event Bus | Y (goldrush compiled) | N | N | N | N | N | N | N |
| Concurrency Model | BEAM (30+ processes) | Single event loop | Single thread | Electron | Single thread | Tokio async | Tokio async | Async Python |

## LLM Provider Support

| Provider | OSA | OpenClaw | Aider | Cursor | Cline | Goose | Codex CLI | OpenHands |
|----------|-----|----------|-------|--------|-------|-------|-----------|-----------|
| Anthropic | Y | Y | Y | Y | Y | Y | N | Y |
| OpenAI | Y | Y | Y | Y | Y | Y | Y | Y |
| Google Gemini | Y | Y | Y | Y | Y | Y | N | Y |
| Ollama (local) | Y | Y | Y | N | Y | Y | N | Y |
| Groq | Y | Y | P | N | P | P | N | P |
| DeepSeek | Y | Y | Y | N | Y | P | N | Y |
| OpenRouter | Y | Y | Y | N | Y | P | N | P |
| Fireworks | Y | N | P | N | N | P | N | N |
| Together AI | Y | N | P | N | N | P | N | N |
| Qwen/Zhipu/Moonshot | Y | N | N | N | N | N | N | N |
| **Total Providers** | **18** | **15+** | **10+** | **4** | **8+** | **6+** | **1** | **6+** |

## Multi-Agent & Orchestration

| Feature | OSA | OpenClaw | Aider | Cursor | Cline | Goose | Codex CLI | OpenHands |
|---------|-----|----------|-------|--------|-------|-------|-----------|-----------|
| Multi-agent orchestration | Y (waves, 9 roles) | P (Lobster) | N | Y (8 parallel) | N | P (subagents) | P (experimental) | Y (hierarchy) |
| Swarm patterns | Y (10 presets) | N | N | N | N | N | N | N |
| Agent roles | Y (9 roles) | N | N | N | N | N | N | P (agent hub) |
| Wave execution | Y (5 waves) | N | N | N | N | N | N | N |
| Inter-agent messaging | Y (mailbox) | N | N | N | N | N | N | P |
| Task decomposition | Y (LLM planner) | P | N | Y (plan mode) | P (plan/act) | P (recipes) | N | Y |
| Dependency tracking | Y | N | N | N | N | N | N | P |
| Agent budget caps | Y (per-agent) | N | N | N | N | N | N | N |
| **Max parallel agents** | **10** | **1** | **1** | **8** | **1** | **3-5** | **2** | **10+** |

## Memory & Learning

| Feature | OSA | OpenClaw | Aider | Cursor | Cline | Goose | Codex CLI | OpenHands |
|---------|-----|----------|-------|--------|-------|-------|-----------|-----------|
| Session persistence | Y (JSONL) | Y (Markdown) | P (git) | N | N | Y (named sessions) | N | N |
| Long-term memory | Y (MEMORY.md) | Y (Markdown) | N | N | N | N | N | N |
| Semantic search | Y (keyword index) | Y (vector + text) | N | N | N | N | N | N |
| RAG retrieval | P (episodic ETS) | Y (SQLite + embeddings) | N | N | N | N | N | N |
| Self-learning | Y (SICA engine) | N | N | N | N | N | N | N |
| Error recovery learning | Y (VIGIL taxonomy) | N | N | N | N | N | N | N |
| Knowledge synthesis | Y (Cortex) | N | N | N | N | N | N | N |
| Pattern consolidation | Y (auto @ 5/50 interactions) | N | N | N | N | N | N | N |
| Context compaction | Y (3-zone progressive) | Y (basic) | N | P | N | N | N | P |

## Signal Intelligence (OSA Exclusive)

| Feature | OSA | OpenClaw | All Others |
|---------|-----|----------|-----------|
| 5-tuple signal classification | Y | N | N |
| Two-tier noise filtering | Y | N | N |
| Communication profiling | Y | N | N |
| Conversation depth tracking | Y | N | N |
| Proactive engagement monitoring | Y | N | N |
| Message quality scoring | Y | N | N |

## CLI & Interface

| Feature | OSA | OpenClaw | Aider | Cursor | Cline | Goose | Codex CLI | OpenHands |
|---------|-----|----------|-------|--------|-------|-------|-----------|-----------|
| Interactive CLI | Y | Y | Y | N | N | Y | Y | P |
| Markdown rendering | Y (ANSI) | Y | Y | — | — | Y | Y | — |
| Slash commands | Y (30+) | Y (150+) | Y | Y | Y | Y | Y | P |
| Progress display | Y (spinner + task) | Y | P | Y | Y | P | Y | Y (web) |
| Session management | Y | Y | N | N | N | Y | N | Y |
| IDE integration | N | N | P (comments) | Y (native) | Y (VS Code) | P | N | N |
| Web dashboard | N | Y (Control UI) | N | — | — | Y (desktop) | N | Y |
| Voice input | N | Y (TTS/STT) | Y | N | N | N | Y | N |
| Browser automation | N | Y (CDP) | N | Y (built-in) | Y (Computer Use) | N | N | Y (sandboxed) |

## Messaging Channels

| Channel | OSA | OpenClaw | All Others |
|---------|-----|----------|-----------|
| Telegram | Y | Y | N |
| Discord | Y | Y | N |
| Slack | Y | Y | N |
| WhatsApp | Y | Y | N |
| Signal | Y | Y | N |
| Matrix | Y | Y | N |
| Email | Y | Y | N |
| QQ | Y | N | N |
| DingTalk | Y | N | N |
| Feishu | Y | N | N |
| iMessage | N | Y | N |
| Teams | N | Y | N |
| Google Chat | N | Y | N |
| **Total** | **12+** | **50+** | **0** |

## Security & Sandboxing

| Feature | OSA | OpenClaw | Aider | Cursor | Cline | Goose | Codex CLI | OpenHands |
|---------|-----|----------|-------|--------|-------|-------|-----------|-----------|
| Docker sandbox | Y (warm pool) | Y (opt-in) | N | N | N | N | P | Y (required) |
| WASM sandbox | Y (experimental) | N | N | N | N | N | N | N |
| JWT authentication | Y | Y | — | — | — | — | — | — |
| Request integrity (HMAC) | Y | N | — | — | — | — | — | — |
| Approval modes | N | N | N | N | Y (per-step) | N | Y (3 modes) | P |
| Tool gating | Y (by model size) | N | N | N | N | N | N | N |
| Permission system | Y (SDK) | P | N | P | Y | N | Y | P |

## Scheduling & Automation

| Feature | OSA | OpenClaw | All Others |
|---------|-----|----------|-----------|
| Heartbeat system | Y (HEARTBEAT.md) | Y (30min default) | N |
| Cron scheduling | Y (CRONS.json) | Y | N |
| Event triggers | Y (TRIGGERS.json) | P | N |
| Circuit breaker | Y | N | N |
| Quiet hours | Y | N | N |
| Webhook receivers | Y (CloudEvents) | Y | N |

## Extensibility

| Feature | OSA | OpenClaw | Aider | Cursor | Cline | Goose | Codex CLI | OpenHands |
|---------|-----|----------|-------|--------|-------|-------|-----------|-----------|
| MCP support | Y | N | N | N | Y | Y (1700+) | Y | N |
| Custom skills | Y (SKILL.md) | Y (2857+ marketplace) | N | P (rules) | P | Y (skills) | N | P (agent hub) |
| Custom commands | Y (30+) | Y (150+) | P | Y (slash) | P | Y (recipes) | P | N |
| Hook pipeline | Y (7 events, 16 hooks) | Y (13 hooks) | N | P | N | N | N | N |
| Skill marketplace | N | Y (ClawHub) | N | N | N | N | N | N |
| Plugin ecosystem | P | Y (37 plugins) | N | Y (extensions) | Y (MCP) | Y (MCP) | Y (MCP) | P |
| Runtime skill creation | Y | N | N | N | N | N | N | N |

## SDK & API

| Feature | OSA | OpenClaw | All Others |
|---------|-----|----------|-----------|
| HTTP API | Y (Plug/Bandit 8089) | Y (Gateway WebSocket) | N (mostly) |
| REST endpoints | Y (orchestrate, swarm, skills) | Y | N |
| SDK contracts | Y (Agent, Config, Hook, Message, Permission, Session, Tool) | P | N |
| CloudEvents protocol | Y | N | N |
| Programmatic agent creation | Y | P | N |

## Financial & Budget

| Feature | OSA | All Others |
|---------|-----|-----------|
| Per-provider cost tracking | Y | N |
| Per-agent budget caps | Y | N |
| Daily/monthly limits | Y | N |
| Treasury governance | Y | N |
| Task value appraisal | Y | N |
| Token usage reporting | Y | P (some) |

## Infrastructure

| Feature | OSA | OpenClaw | Others |
|---------|-----|----------|--------|
| OTA updates (TUF) | Y | Y (npm) | N |
| Fleet management | Y (opt-in) | N | N |
| Go sidecars (tokenizer, git, sysmon) | Y | N | N |
| Python sidecar (embeddings) | Y | N | N |
| Sidecar circuit breaker | Y | N | N |
| OS template discovery | Y | N | N |
