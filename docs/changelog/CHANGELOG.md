# Changelog

All notable changes to OptimalSystemAgent are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

---

## [Unreleased]

### Added
- Competitive intelligence docs (`docs/competitors/`)
- Feature matrix comparing 14 competitors
- 5-phase roadmap with gap analysis
- Changelog structure

---

## [0.9.0] - 2026-02-27

### Added
- **Data pipeline hardening**: 7 security/correctness fixes from review
- **Channel onboarding**: guided first-run setup for each messaging platform
- **WhatsApp Web sidecar**: experimental WhatsApp integration
- **SQLite message persistence**: messages survive restarts
- **Formatter pass**: consistent code formatting across codebase

### Fixed
- 5 model switching edge cases (`/model`, `/tiers`)
- Tool process instructions + GLM-4 model matching
- `runtime.exs` configuration fix

---

## [0.8.0] - 2026-02-26

### Added
- **12-feature extension**:
  - Request integrity (HMAC-SHA256 + nonce deduplication)
  - Per-agent budget governance
  - Persistent task queue with atomic leasing
  - CloudEvents protocol support
  - Fleet management (opt-in) with registry and health monitoring
  - Heartbeat state persistence with quiet hours
  - WASM sandbox (experimental)
  - Treasury governance (deposits, withdrawals, reservations)
  - Business skills (wallet operations)
  - Task value appraiser with role-based costing
  - Crypto wallet integration (mock, Base USDC, Ethereum, Solana)
  - OTA updater with TUF verification

---

## [0.7.0] - 2026-02-25

### Added
- **Agent dispatch system**: 22+ agents with tier assignments
- **9-role orchestration**: lead, backend, frontend, data, design, infra, qa, red_team, services
- **Wave execution**: 5-phase dependency-aware orchestration
- **10 swarm presets**: code-analysis, full-stack, debug, performance-audit, security-audit, documentation, adaptive-debug, adaptive-feature, concurrent-migration, ai-pipeline
- **Tier-aware model routing**: elite/opus, specialist/sonnet, utility/haiku
- **Hook pipeline**: 7 events, 16+ built-in hooks
- **SICA learning engine**: OBSERVE → REFLECT → PROPOSE → TEST → INTEGRATE
- **VIGIL error taxonomy**: structured error recovery
- **Cortex knowledge synthesis**: cross-session topic tracking

---

## [0.6.0] - 2026-02-24

### Added
- **Signal Theory framework**: 5-tuple classification (Mode, Genre, Type, Format, Weight)
- **Two-tier noise filtering**: deterministic (<1ms) + LLM fallback (~200ms)
- **Communication intelligence**: profiler, coach, conversation tracker, contact detector, proactive monitor
- **Context management**: 4-tier token-budgeted assembly
- **3-zone progressive compaction**: hot/warm/cold with importance weighting

---

## [0.5.0] - 2026-02-23

### Added
- **18 LLM providers**: Anthropic, OpenAI, Google, Ollama, Groq, Fireworks, Together, Replicate, DeepSeek, OpenRouter, Perplexity, Qwen, Zhipu, Moonshot, VolcEngine, Baichuan
- **Provider auto-detection**: env vars → API keys → Ollama fallback
- **Tool gating**: model size and capability-aware tool dispatch
- **.env loading**: project root + `~/.osa/.env`
- **Ollama integration**: auto-detect largest tool-capable model

---

## [0.4.0] - 2026-02-22

### Added
- **Swarm system**: orchestrator, patterns, intelligence, mailbox, worker, planner, PACT framework
- **4 swarm patterns**: parallel, pipeline, debate, review_loop
- **5 swarm roles**: coordinator, researcher, implementer, reviewer, synthesizer
- **Inter-agent messaging**: mailbox-based communication

---

## [0.3.0] - 2026-02-21

### Added
- **12+ messaging channels**: CLI, HTTP, Telegram, Discord, Slack, WhatsApp, Signal, Matrix, Email, QQ, DingTalk, Feishu
- **Channel manager**: auto-start configured channels
- **Channel onboarding**: first-run configuration per platform
- **HTTP API**: Plug/Bandit on port 8089 with REST endpoints
- **SDK contracts**: Agent, Config, Hook, Message, Permission, Session, Tool

---

## [0.2.0] - 2026-02-20

### Added
- **9 built-in skills**: file_read, file_write, shell_execute, web_search, memory_save, orchestrate, create_skill, budget_status, wallet_ops
- **Skill system**: Behaviour callbacks, Registry, SKILL.md format, MCP integration
- **Memory system**: 3-store architecture (session JSONL, long-term MEMORY.md, episodic ETS)
- **Session management**: JSONL persistence, resume, registry

---

## [0.1.0] - 2026-02-19

### Added
- **Core agent loop**: ReAct stateful agent with message processing
- **OTP application**: supervisor tree with 25+ subsystems
- **Event bus**: goldrush-compiled zero-overhead routing
- **CLI**: interactive terminal with markdown rendering, spinner, readline
- **Onboarding**: first-run wizard (agent name, profile, provider, channels)
- **Docker sandbox**: warm container pool, executor, resource limits
- **Go sidecars**: tokenizer, git, sysmon
- **Python sidecar**: embeddings
- **Sidecar management**: lifecycle, circuit breaker, health polling
- **30+ slash commands**: /help, /status, /model, /skills, /memory, /agents, /tiers, etc.
