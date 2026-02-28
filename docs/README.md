# OSA Documentation

> OptimalSystemAgent — The AI Agent Framework on Elixir/OTP
>
> 39,500+ LOC | 154 modules | 18 providers | 12+ channels | 627 tests

---

## Getting Started

| Doc | Description |
|-----|-------------|
| [Overview](getting-started/) | Installation, prerequisites, quick start |
| [Configuration](getting-started/configuration.md) | All config options, env vars, feature flags |
| [Troubleshooting](getting-started/troubleshooting.md) | Common issues and solutions |

## Architecture

| Doc | Description |
|-----|-------------|
| [Overview](architecture/) | OTP supervision tree, module map, system design |
| [Signal Theory](architecture/signal-theory.md) | 5-tuple classification, noise filtering, communication intelligence |
| [Memory & Learning](architecture/memory-and-learning.md) | 3-store memory, SICA learning engine, Cortex synthesis |
| [SDK Architecture](architecture/sdk.md) | SDK contracts, agent lifecycle, session management |

## Guides

| Doc | Description |
|-----|-------------|
| [Providers](guides/providers/) | 18 LLM providers — per-provider setup guides |
| [Channels](guides/channels/) | 12+ channels — per-channel setup guides |
| [Orchestration](guides/orchestration.md) | 9 roles, 5 waves, 10 swarm patterns, tier routing |
| [Hook Pipeline](guides/hooks.md) | 7 events, 16+ hooks, custom hook development |
| [Skills](guides/skills.md) | Creating built-in and SKILL.md custom skills |

### Provider Guides

| Provider | Guide |
|----------|-------|
| Anthropic (Claude) | [anthropic.md](guides/providers/anthropic.md) |
| OpenAI | [openai.md](guides/providers/openai.md) |
| Google (Gemini) | [google.md](guides/providers/google.md) |
| Groq (LPU) | [groq.md](guides/providers/groq.md) |
| DeepSeek | [deepseek.md](guides/providers/deepseek.md) |
| Fireworks | [fireworks.md](guides/providers/fireworks.md) |
| Together AI | [together.md](guides/providers/together.md) |
| OpenRouter | [openrouter.md](guides/providers/openrouter.md) |
| Perplexity | [perplexity.md](guides/providers/perplexity.md) |
| Mistral | [mistral.md](guides/providers/mistral.md) |
| Cohere | [cohere.md](guides/providers/cohere.md) |
| Replicate | [replicate.md](guides/providers/replicate.md) |
| Ollama (Local) | [ollama.md](guides/providers/ollama.md) |
| Chinese (Qwen, Zhipu, Moonshot, VolcEngine, Baichuan) | [chinese.md](guides/providers/chinese.md) |

### Channel Guides

| Channel | Guide |
|---------|-------|
| CLI | [cli.md](guides/channels/cli.md) |
| HTTP API | [http.md](guides/channels/http.md) |
| Telegram | [telegram.md](guides/channels/telegram.md) |
| Discord | [discord.md](guides/channels/discord.md) |
| Slack | [slack.md](guides/channels/slack.md) |
| WhatsApp | [whatsapp.md](guides/channels/whatsapp.md) |
| Signal | [signal.md](guides/channels/signal.md) |
| Matrix | [matrix.md](guides/channels/matrix.md) |
| Email | [email.md](guides/channels/email.md) |
| DingTalk | [dingtalk.md](guides/channels/dingtalk.md) |
| Feishu | [feishu.md](guides/channels/feishu.md) |
| QQ | [qq.md](guides/channels/qq.md) |

## TUI (Terminal UI)

| Doc | Description |
|-----|-------------|
| [Overview](tui/README.md) | Architecture, build, and run instructions |
| [Roadmap](tui/roadmap.md) | Development history, state machine, completed features, planned work |
| [Known Issues](tui/bugs.md) | Bug tracker, pipeline audit, recently fixed issues |

## Reference

| Doc | Description |
|-----|-------------|
| [CLI Commands](reference/cli.md) | 60+ slash commands organized by category |
| [HTTP API](reference/http-api.md) | REST endpoints, authentication, request/response formats |

## Concepts

| Doc | Description |
|-----|-------------|
| [Use Cases](concepts/use-cases.md) | Real-world usage patterns and workflows |

## Operations

| Doc | Description |
|-----|-------------|
| [Deployment](operations/deployment.md) | Docker, systemd, Nginx, production checklist |
| [Debugging Journal](operations/debugging-journal.md) | Historical debugging notes and resolutions |

## Competitive Intelligence

| Doc | Description |
|-----|-------------|
| [Competitors Overview](competitors/README.md) | 14 competitors analyzed, positioning map |
| [Feature Matrix](competitors/feature-matrix.md) | Side-by-side comparison across all competitors |
| [OSA vs OpenClaw](competitors/osa-vs-openclaw-hitlist.md) | Head-to-head deep dive |
| [OpenClaw](competitors/openclaw.md) | 195K stars, messaging-first — our #1 comp |
| [Aider](competitors/aider.md) | SOTA CLI coding agent |
| [Cursor](competitors/cursor.md) | Best AI IDE, 8 parallel agents |
| [All Competitors](competitors/) | Cline, Goose, Codex CLI, OpenHands, SWE-Agent, Devin, etc. |

## Roadmap

| Doc | Description |
|-----|-------------|
| [Roadmap Overview](roadmap/README.md) | 5-phase strategy, success metrics |
| [Gap Analysis](roadmap/gap-analysis.md) | What competitors have that we don't — prioritized |
| [Our Advantages](roadmap/our-advantages.md) | 15 features that exist nowhere else |
| [Phase 1: Foundation](roadmap/phase-1-foundation.md) | Mar 2026 — embeddings, git workflow, benchmarks |
| [Phase 2: Developer Experience](roadmap/phase-2-developer-experience.md) | Apr 2026 — browser, IDE, worktrees |
| [Phase 3: Reach](roadmap/phase-3-reach.md) | May 2026 — web UI, more channels, TUI |
| [Phase 4: Ecosystem](roadmap/phase-4-ecosystem.md) | Jun 2026 — marketplace, voice, PM integrations |
| [Phase 5: Platform](roadmap/phase-5-platform.md) | Q3 2026 — mobile, cloud, enterprise |

## Changelog

| Doc | Description |
|-----|-------------|
| [Changelog](changelog/CHANGELOG.md) | All releases and notable changes |

---

## Directory Structure

```
docs/
├── README.md                      ← You are here
├── getting-started/               ← Install, config, troubleshooting
│   ├── README.md
│   ├── configuration.md
│   └── troubleshooting.md
├── architecture/                  ← System design & internals
│   ├── README.md
│   ├── signal-theory.md
│   ├── memory-and-learning.md
│   └── sdk.md
├── guides/                        ← How-to guides
│   ├── README.md
│   ├── providers/                 ← Per-provider setup (14 files)
│   │   ├── README.md
│   │   ├── anthropic.md
│   │   ├── openai.md
│   │   ├── google.md
│   │   ├── groq.md
│   │   ├── deepseek.md
│   │   ├── fireworks.md
│   │   ├── together.md
│   │   ├── openrouter.md
│   │   ├── perplexity.md
│   │   ├── mistral.md
│   │   ├── cohere.md
│   │   ├── replicate.md
│   │   ├── ollama.md
│   │   └── chinese.md
│   ├── channels/                  ← Per-channel setup (12 files)
│   │   ├── README.md
│   │   ├── cli.md
│   │   ├── http.md
│   │   ├── telegram.md
│   │   ├── discord.md
│   │   ├── slack.md
│   │   ├── whatsapp.md
│   │   ├── signal.md
│   │   ├── matrix.md
│   │   ├── email.md
│   │   ├── dingtalk.md
│   │   ├── feishu.md
│   │   └── qq.md
│   ├── orchestration.md
│   ├── hooks.md
│   └── skills.md
├── tui/                           ← Go terminal UI
│   ├── README.md
│   ├── roadmap.md
│   └── bugs.md
├── reference/                     ← API & CLI reference
│   ├── README.md
│   ├── cli.md
│   └── http-api.md
├── concepts/                      ← High-level concepts
│   ├── README.md
│   └── use-cases.md
├── operations/                    ← Deployment & ops
│   ├── README.md
│   ├── deployment.md
│   └── debugging-journal.md
├── competitors/                   ← Competitive intelligence (17 files)
│   ├── README.md
│   ├── feature-matrix.md
│   ├── osa-vs-openclaw-hitlist.md
│   ├── openclaw.md
│   ├── aider.md
│   ├── cursor.md
│   └── ... (11 more)
├── roadmap/                       ← 5-phase plan (8 files)
│   ├── README.md
│   ├── gap-analysis.md
│   ├── our-advantages.md
│   └── phase-1..5-*.md
└── changelog/
    └── CHANGELOG.md
```

## System Stats

| Metric | Value |
|--------|-------|
| Lines of code | 39,500+ |
| Elixir modules | 154 |
| Test cases | 627 |
| LLM providers | 18 |
| Messaging channels | 12+ |
| Built-in skills | 9 |
| Markdown skills | 30+ |
| Agent roles | 9 |
| Swarm presets | 10 |
| Slash commands | 60+ |
| Hook events | 7 |
| Built-in hooks | 16+ |
| Doc files | 60+ |
