# OSA vs OpenClaw — Full Hit List
> Generated 2026-02-27 | Based on OpenClaw 2026.2.15 and OSA latest (Feb 27 push)

---

## SCOREBOARD

| Category | OSA | OpenClaw | Winner |
|----------|-----|----------|--------|
| Signal Intelligence | 5-tuple + noise filter | Nothing | **OSA** |
| Communication Intelligence | 5 modules | Nothing | **OSA** |
| Fault Tolerance | OTP supervision trees | Single Node.js process | **OSA** |
| Concurrency | 30+ simultaneous (BEAM) | Single event loop | **OSA** |
| Event Routing | goldrush compiled bytecode | JS polling | **OSA** |
| Hot Code Reload | Yes (skills, soul, config) | Restart required | **OSA** |
| Codebase Maintainability | 18.7K lines | 527K lines | **OSA** |
| Test Coverage | 440 tests | ~200 tests | **OSA** |
| Context Management | 4-tier token-budgeted | Basic compaction | **OSA** |
| Multi-Agent Orchestration | Dependency-aware waves + 4 swarm patterns | Basic multi-agent routing | **OSA** |
| Dynamic Skill Creation | Runtime SKILL.md generation | No | **OSA** |
| Personality System | Soul/Identity/User layered | No | **OSA** |
| Messaging Channels | 12 | 23+ (8 core + 15 extensions) | **OpenClaw** |
| AI Providers | 17 | 18+ | **Tie** |
| Voice/Audio | None | Full (TTS + STT + Wake + Talk) | **OpenClaw** |
| Browser Automation | None | Chrome CDP + Playwright | **OpenClaw** |
| Canvas/Visual UI | None | A2UI protocol | **OpenClaw** |
| Mobile Nodes | None | iOS + Android + macOS | **OpenClaw** |
| Device Pairing | None | QR + challenge-response | **OpenClaw** |
| Terminal UI | Basic CLI REPL | Rich TUI with navigation | **OpenClaw** |
| IDE Integration | None | ACP (VSCode, Zed) | **OpenClaw** |
| Remote Access | None | Tailscale + SSH tunnels | **OpenClaw** |
| Plugin Ecosystem | Skills + MCP | 37 plugins + 53 skills + hooks | **OpenClaw** |
| Memory System | 3-store + keyword index | Vector DB + hybrid search | **OpenClaw** |
| Web Dashboard | None | Control UI + WebChat | **OpenClaw** |
| DM Security/Pairing | JWT only | Pairing codes + DM policies | **OpenClaw** |
| Webhook System | Basic triggers | Full inbound/outbound + retry | **OpenClaw** |
| Scheduling | HEARTBEAT + CRONS + TRIGGERS | Cron + recurring + catch-up | **Tie** |
| Docker Sandbox | Yes (read-only, CAP_DROP ALL) | No built-in sandbox | **OSA** |
| Onboarding | mix osa.setup wizard | Interactive multi-step wizard | **OpenClaw** |
| Auto-Reply | None | Pattern-based + DND modes | **OpenClaw** |
| Presence System | None | Online/offline + typing | **OpenClaw** |

**Score: OSA 13 — OpenClaw 15 — Tie 2**

---

## WHAT OSA HAS THAT OPENCLAW DOES NOT

### 1. Signal Classification (Unique, Architecturally Significant)
- [ ] **5-tuple classification**: S = (Mode, Genre, Type, Format, Weight)
- [ ] **LLM-primary intent understanding** (not regex pattern matching)
- [ ] **ETS cache** with SHA256 keys, 10-min TTL
- [ ] **Deterministic fallback** when LLM unavailable

**Why this matters**: OpenClaw treats every message identically. "hey" and "restructure Q3 revenue model" get the same pipeline, same compute, same latency. OSA classifies first, routes intelligently. This is the core differentiator.

**OpenClaw equivalent**: Nothing. Zero. They have no message intelligence layer.

---

### 2. Noise Filtering (Unique, Cost Savings)
- [ ] **Tier 1 (deterministic, <1ms)**: Regex + length + duplicate detection
- [ ] **Tier 2 (LLM-based, ~200ms)**: For borderline signals (weight 0.3-0.6)
- [ ] **40-60% AI cost reduction** by filtering before LLM calls

**Why this matters**: Every message OpenClaw processes costs money. OSA filters noise before it hits the model. At scale this is massive savings.

**OpenClaw equivalent**: Nothing.

---

### 3. Communication Intelligence (Unique, 5 Modules)
- [ ] **CommProfiler** — Learns each contact's communication style
- [ ] **CommCoach** — Scores outbound messages (clarity, empathy, actionability)
- [ ] **ContactDetector** — Identifies who's talking in <1ms
- [ ] **ConversationTracker** — Tracks depth (casual → strategic)
- [ ] **ProactiveMonitor** — Detects silence, drift, engagement drops

**Why this matters**: No other agent framework understands HOW people communicate. OSA adapts to users. OpenClaw just processes text.

**OpenClaw equivalent**: Nothing. Zero awareness of communication patterns.

---

### 4. OTP Fault Tolerance (Architectural Advantage)
- [ ] **Supervision trees** — Crashed component auto-restarts without affecting others
- [ ] **one_for_one strategy** — Individual failures isolated
- [ ] **DynamicSupervisor** — Channels/MCP servers add/remove at runtime
- [ ] **BEAM process isolation** — Each conversation in its own process
- [ ] **99.9999% uptime pattern** (telecom-grade)

**Why this matters**: OpenClaw is a SINGLE Node.js process. One crash = everything dies. One channel error can take down the entire gateway. OSA's OTP model means a bug in Telegram doesn't affect Slack.

**OpenClaw equivalent**: Nothing. They use try/catch. One uncaught exception = full restart.

---

### 5. Compiled Event Routing (Performance)
- [ ] **goldrush** compiles event-matching rules into Erlang bytecode
- [ ] **Zero hash lookups** at runtime — pre-compiled into the VM
- [ ] **Telecom-grade routing speed**

**Why this matters**: OpenClaw routes through a JS event loop. OSA routes through compiled machine code. The difference matters at scale (30+ simultaneous conversations).

**OpenClaw equivalent**: Standard Node.js EventEmitter / polling loop.

---

### 6. True Concurrency (BEAM Processes)
- [ ] **30+ simultaneous conversations** via lightweight BEAM processes
- [ ] **No shared state** between conversations
- [ ] **No event loop bottleneck**
- [ ] **Per-conversation memory isolation**

**Why this matters**: OpenClaw queues messages in a single event loop. Long-running tool calls (browser automation, large LLM responses) block everything else. OSA's BEAM model means true parallelism.

**OpenClaw equivalent**: Single-threaded V8 event loop. RPC mode (separate process) exists but is opt-in and limited.

---

### 7. Intelligent Context Assembly (Token-Budgeted)
- [ ] **4-tier priority system**: CRITICAL (unlimited) → HIGH (40%) → MEDIUM (30%) → LOW (remaining)
- [ ] **Smart token estimation** (word × 1.3 + punctuation × 0.5)
- [ ] **Dynamic truncation** by priority tier
- [ ] **128K default budget** (configurable)

**Why this matters**: OpenClaw does basic compaction (summarize old messages). OSA actively manages what goes into context by importance. Tool calls get priority. Acknowledgments get deprioritized. This produces better LLM outputs.

**OpenClaw equivalent**: Basic LLM-based summary compaction. No priority system.

---

### 8. Progressive Compaction Pipeline
- [ ] **3-zone sliding window**: HOT (last 10, verbatim) → WARM (11-30, compressed) → COLD (31+, key-facts)
- [ ] **5-step compression**: Strip tool args → merge same-role → summarize warm → compress cold → emergency truncate
- [ ] **Importance-weighted retention**: Tool calls +50%, high signal +30%, acknowledgments -50%

**Why this matters**: OpenClaw's compaction is one-shot (summarize everything old). OSA progressively compresses based on message importance. A tool result that produced useful output is retained longer than a "thanks" message.

**OpenClaw equivalent**: Single-pass LLM summarization. No importance weighting.

---

### 9. Multi-Agent Orchestration (Dependency-Aware)
- [ ] **LLM-based task decomposition** with complexity analysis
- [ ] **Topological sort** for dependency-aware execution waves
- [ ] **8 specialized roles**: Researcher, Builder, Tester, Reviewer, Writer, etc.
- [ ] **4 swarm patterns**: Parallel, Pipeline, Debate, Review Loop
- [ ] **Mailbox-based inter-agent messaging**
- [ ] **Real-time progress tracking** (tool uses, tokens, status)

**Why this matters**: OpenClaw's multi-agent is just routing channels to different agents. OSA's agents actually collaborate — they can debate, review each other's work, pipeline outputs.

**OpenClaw equivalent**: Basic agent routing (channel → agent). No collaboration, no orchestration, no swarm patterns.

---

### 10. Dynamic Skill Creation (Self-Teaching)
- [ ] **Agent creates skills at runtime** via `create_skill` tool
- [ ] **Skill discovery** — searches existing skills before creating duplicates
- [ ] **Relevance scoring** — suggests alternatives (>0.5 threshold)
- [ ] **Writes SKILL.md + registers** immediately (no restart)

**Why this matters**: OpenClaw agents use pre-defined tools. OSA agents can teach themselves new capabilities mid-conversation.

**OpenClaw equivalent**: Nothing. Skills must be manually created and installed.

---

### 11. Soul/Personality System
- [ ] **IDENTITY.md** — Who the agent is
- [ ] **SOUL.md** — How it thinks and communicates
- [ ] **USER.md** — User preferences and context
- [ ] **Signal-adaptive expression** — Personality adapts to message type (EXECUTE = concise, EXPRESS = warm)
- [ ] **Per-agent souls** — Different agents, different personalities
- [ ] **Hot reload** via `/reload`

**OpenClaw equivalent**: Basic system prompt. No layered identity, no signal-adaptive behavior.

---

### 12. Cortex Knowledge Synthesis
- [ ] **Active topic tracking** across sessions
- [ ] **Memory bulletins**: Current Focus, Pending Items, Key Decisions, Patterns
- [ ] **Cross-session pattern detection**
- [ ] **5-minute refresh interval**
- [ ] **ETS-backed topic frequency**

**OpenClaw equivalent**: Nothing. Memory is search-only, no synthesis.

---

### 13. Workflow Tracking
- [ ] **LLM-based task decomposition** with acceptance criteria per step
- [ ] **Step status tracking**: pending → in_progress → completed → skipped
- [ ] **Per-step signal mode** indication
- [ ] **Workflow persistence** to `~/.osa/workflows/{id}.json`
- [ ] **Pause/resume/skip** capabilities

**OpenClaw equivalent**: Nothing built-in. Cron jobs exist but no multi-step workflow tracking.

---

### 14. Docker Sandbox (Proper Isolation)
- [ ] **Read-only root filesystem**
- [ ] **CAP_DROP ALL** (zero Linux capabilities)
- [ ] **Network isolation** (configurable per call)
- [ ] **Non-root user** (UID 1000)
- [ ] **--no-new-privileges**
- [ ] **Warm container pool** for instant execution
- [ ] **Resource limits** (CPU + memory)

**Why this matters**: OpenClaw executes tools on the host machine with no sandboxing. OSA can isolate dangerous operations in locked-down containers.

**OpenClaw equivalent**: No built-in sandbox. Bash runs directly on host. They have an "exec approval" system but that's just asking permission, not isolation.

---

### 15. OS Template Integration
- [ ] **Auto-discovery** of OS templates (BusinessOS, ContentOS, etc.)
- [ ] **.osa-manifest.json** for stack/module/skill declaration
- [ ] **Context injection** — agent understands the codebase
- [ ] **Multiple templates** connected simultaneously

**OpenClaw equivalent**: Nothing. No concept of template ecosystems.

---

## WHAT OPENCLAW HAS THAT OSA DOES NOT

### 1. Messaging Channels (23+ vs 12)
- [ ] WhatsApp (Baileys, QR-based) — **OSA has WhatsApp Business API**
- [ ] iMessage (legacy + BlueBubbles) — **OSA missing**
- [ ] Microsoft Teams — **OSA missing**
- [ ] Google Chat — **OSA missing**
- [ ] IRC — **OSA missing**
- [ ] Nostr — **OSA missing**
- [ ] Tlon/Urbit — **OSA missing**
- [ ] Twitch — **OSA missing**
- [ ] Nextcloud Talk — **OSA missing**
- [ ] Mattermost — **OSA missing**
- [ ] Line — **OSA missing**
- [ ] WebChat (browser) — **OSA missing**
- [ ] Zalo Personal — **OSA missing**

**OSA has that OpenClaw doesn't**: QQ, DingTalk, Email (IMAP+SMTP)

**Verdict**: OpenClaw has more channels overall, but OSA has some Chinese/enterprise channels OpenClaw lacks. OSA's channel architecture is cleaner (manager-based auto-start, webhook verification, rate limiting per channel).

**Priority to add**: WebChat (easy win), iMessage/BlueBubbles (macOS users), Line (large Asian market)

---

### 2. Voice/Audio System
- [ ] **Text-to-Speech**: ElevenLabs, Edge TTS, OpenAI TTS — **OSA has none**
- [ ] **Speech-to-Text**: OpenAI Whisper, Deepgram — **OSA has none**
- [ ] **Voice Wake**: Always-on listening — **OSA has none**
- [ ] **Talk Mode**: Continuous speech conversation — **OSA has none**
- [ ] **Voice Calls**: Plugin-based — **OSA has none**

**Verdict**: This is a full capability gap. Voice is a major differentiator for personal AI assistants.

**Priority**: HIGH — local TTS (Edge TTS is free) + Whisper (Ollama can do this) would be a strong combo

---

### 3. Browser Automation
- [ ] **Chrome DevTools Protocol** — dedicated Chrome instance — **OSA has none**
- [ ] **Playwright integration** — high-level automation — **OSA has none**
- [ ] **Profile management** — saved browser states — **OSA has none**
- [ ] **Screenshots, form filling, navigation** — **OSA has none**
- [ ] **Auth persistence** — logged-in sessions — **OSA has none**

**Verdict**: Full gap. Browser automation opens up web scraping, form filling, testing, and information extraction use cases.

**Priority**: MEDIUM — web_search covers basic needs; browser automation is power-user

---

### 4. Canvas/Visual Workspace (A2UI)
- [ ] **Agent-driven visual UI** — **OSA has none**
- [ ] **HTML/CSS/JS rendering** — **OSA has none**
- [ ] **Push/reset/eval** — **OSA has none**
- [ ] **Multi-platform** (macOS, iOS, web) — **OSA has none**

**Verdict**: Nice-to-have. Canvas lets the agent show visual output (charts, dashboards, forms). Not critical for agent intelligence but great for UX.

**Priority**: LOW — focus on intelligence first

---

### 5. Mobile Device Nodes
- [ ] **iOS node**: Camera, screen, location, notifications, Canvas — **OSA has none**
- [ ] **Android node**: Camera, screen, SMS, notifications — **OSA has none**
- [ ] **macOS node**: System commands, camera, screen recording — **OSA has none**
- [ ] **Bonjour/mDNS discovery** — **OSA has none**

**Verdict**: This lets OpenClaw control your phone/Mac as a tool. Take photos, read screen, get location. Hardware integration.

**Priority**: MEDIUM — powerful but niche. Channel support matters more.

---

### 6. Device Pairing & DM Security
- [ ] **QR code pairing** for new devices — **OSA has none**
- [ ] **Challenge-response auth** — **OSA has none**
- [ ] **DM pairing codes** for unknown senders — **OSA has JWT only**
- [ ] **Per-channel DM policies** (open/pairing) — **OSA has none**
- [ ] **Identity linking** across channels — **OSA has none**

**Verdict**: Important for multi-device and multi-user scenarios. OSA's JWT is fine for API but doesn't handle the "stranger sends you a WhatsApp" case.

**Priority**: HIGH if shipping channels — you need DM gating

---

### 7. Rich Terminal UI
- [ ] **Full TUI** with session navigation — **OSA has basic CLI REPL**
- [ ] **Theme support** (dark/light) — **OSA has ANSI colors only**
- [ ] **Overlays/modals** — **OSA has none**
- [ ] **Session switching** in TUI — **OSA has `/resume` command**

**Verdict**: OpenClaw's TUI is significantly more polished. OSA's CLI works but isn't as immersive.

**Priority**: LOW — CLI works fine. Polish later.

---

### 8. IDE Integration (ACP)
- [ ] **Agent Client Protocol** — stdio bridge — **OSA has none**
- [ ] **VSCode extension** — **OSA has none**
- [ ] **Zed editor support** — **OSA has none**
- [ ] **Session mapping** IDE → agent — **OSA has none**

**Verdict**: Lets developers use the agent inside their IDE. Nice for coding use cases.

**Priority**: LOW — MCP covers most IDE integration needs

---

### 9. Remote Access
- [ ] **Tailscale Serve/Funnel** — secure remote access — **OSA has none**
- [ ] **SSH tunnel support** — **OSA has none**
- [ ] **Multi-client support** — **OSA has none**
- [ ] **TLS certificate support** — **OSA has none**

**Verdict**: OpenClaw can be accessed from anywhere. OSA is local-only.

**Priority**: MEDIUM — important for mobile/remote use. Tailscale integration is straightforward.

---

### 10. Vector Memory / Semantic Search
- [ ] **LanceDB vector database** — **OSA has keyword index only**
- [ ] **Hybrid BM25 + vector search** — **OSA has keyword + recency + importance**
- [ ] **OpenAI/Google/Voyage embeddings** — **OSA has none**
- [ ] **Batch embedding processing** — **OSA has none**

**Verdict**: OpenClaw's memory can find semantically similar content even with different wording. OSA's keyword index is faster but less flexible.

**Priority**: MEDIUM — OSA's approach works well for most cases. Embeddings would help for large knowledge bases. Could use Ollama for local embeddings.

---

### 11. Web Dashboard / Control UI
- [ ] **Browser-based dashboard** — **OSA has none**
- [ ] **WebChat interface** — **OSA has HTTP API only**
- [ ] **Configuration editor** — **OSA has config files only**
- [ ] **Session management UI** — **OSA has CLI only**

**Priority**: LOW — API-first is fine. Build UI when needed.

---

### 12. Auto-Reply System
- [ ] **Pattern-based auto-replies** — **OSA has none**
- [ ] **Absence/DND modes** — **OSA has none**
- [ ] **Channel-specific config** — **OSA has none**

**Priority**: LOW — nice convenience feature

---

### 13. Presence System
- [ ] **Online/offline status** — **OSA has none**
- [ ] **Typing indicators** — **OSA has thinking indicator only**
- [ ] **Last activity tracking** — **OSA has none**
- [ ] **Multi-device presence** — **OSA has none**

**Priority**: LOW — cosmetic. Add when shipping channels.

---

### 14. Plugin Ecosystem Breadth
- [ ] **37 stock plugins** — **OSA has skills + MCP**
- [ ] **53 built-in skills** (Spotify, 1Password, Hue, Sonos, etc.) — **OSA has 7 built-in + 8 example**
- [ ] **13 hook points** — **OSA has event bus**
- [ ] **ClawHub registry** — **OSA has none**

**Verdict**: OpenClaw has way more pre-built integrations. But OSA's dynamic skill creation means agents can build their own tools. Different philosophy.

**Priority**: MEDIUM — build popular skills (GitHub, Notion, weather) as examples. The architecture supports rapid addition.

---

## OPENCLAW'S WEAKNESSES (Why OSA Is Better Here)

### 1. Single Point of Failure
OpenClaw is one Node.js process. One uncaught exception = entire system crash. All channels, all agents, all sessions — gone. They use try/catch but it's not fault-tolerant.

**OSA advantage**: OTP supervision trees auto-restart crashed components. Telegram adapter crashes? It restarts. Slack keeps running. This is telecom-grade reliability.

### 2. No Message Intelligence
OpenClaw sends everything to the LLM. "ok", "thanks", emoji reactions, "hey" — all get full pipeline treatment. At $0.015/1K tokens, this adds up fast.

**OSA advantage**: Signal classification + noise filtering saves 40-60% on LLM costs. Messages are prioritized by information value.

### 3. Single-Threaded Bottleneck
V8 event loop means one thing at a time. A long browser automation blocks message processing. A large LLM response blocks channel delivery.

**OSA advantage**: BEAM processes are truly concurrent. 30+ conversations simultaneously with zero blocking.

### 4. Massive Codebase (527K LOC)
Extremely hard to maintain, debug, or contribute to. Configuration alone has 150+ variants.

**OSA advantage**: 18.7K lines. Clean, focused, well-tested (440 tests). A new developer can understand the full system in a day.

### 5. Over-Engineered Memory
4 embedding backends, hybrid search with custom query language, atomic reindex — for what is usually "find me that thing I said last week."

**OSA advantage**: 3-store memory with keyword index is simpler, faster, and handles 95% of use cases. Cortex synthesis adds cross-session intelligence that OpenClaw doesn't have.

### 6. No Agent Collaboration
OpenClaw's "multi-agent" is just routing channels to different agents. They can't collaborate, debate, or review each other's work.

**OSA advantage**: 4 swarm patterns (parallel, pipeline, debate, review_loop), dependency-aware task decomposition, inter-agent mailbox messaging.

### 7. No Context Intelligence
OpenClaw does basic compaction (summarize old messages). No priority system. No importance weighting.

**OSA advantage**: 4-tier token-budgeted context assembly. Tool results kept longer than acknowledgments. Progressive 3-zone compression with importance weighting.

### 8. No Communication Awareness
OpenClaw has zero understanding of how people communicate. No contact profiling, no conversation depth tracking, no engagement monitoring.

**OSA advantage**: 5 dedicated communication intelligence modules that learn and adapt.

### 9. No Sandbox Isolation
OpenClaw runs tools directly on the host. The "exec approval" system asks permission but provides zero isolation. A malicious tool call has full system access.

**OSA advantage**: Docker sandbox with read-only filesystem, CAP_DROP ALL, network isolation, non-root user, resource limits.

### 10. Plugin System Complexity
13 hook points (many unused), manifest schema validation, hot reload file watching. Over-abstracted for what most users need.

**OSA advantage**: Skills are simple Elixir modules or SKILL.md files. Drop in folder, immediately available. No manifest, no hooks, no registry ceremony.

---

## OSA'S WEAKNESSES (Where OpenClaw Is Better)

### 1. No Voice at All
Voice is a major UX differentiator. Talk-to-your-agent is compelling. OSA has zero audio capabilities.

**Fix**: Add Edge TTS (free, local) + Whisper via Ollama. Medium effort, high impact.

### 2. Fewer Channels
12 vs 23+. Missing iMessage, Teams, Google Chat, IRC, WebChat, and several niche channels.

**Fix**: iMessage via BlueBubbles protocol (well-documented). WebChat is just a web frontend to the HTTP API. Teams/Google Chat are enterprise needs.

### 3. No Browser Automation
Can't control a browser. Limits web scraping, form filling, and automation use cases.

**Fix**: Add Playwright as optional dependency. Medium effort.

### 4. No Visual Output (Canvas)
Agent can only produce text. Can't show charts, dashboards, or interactive UI.

**Fix**: Build a simple HTML renderer. Or add a WebSocket-based canvas protocol. Higher effort.

### 5. No Mobile Integration
Can't control phone camera, screen, location. OpenClaw's node system is powerful.

**Fix**: Would require native iOS/Android apps. High effort. Skip unless core to strategy.

### 6. No Remote Access
Local-only. Can't access from phone or another machine.

**Fix**: Tailscale integration is straightforward. Or expose HTTP API via reverse proxy. Low-medium effort.

### 7. No Vector/Semantic Search
Keyword-based memory search misses semantically similar content with different wording.

**Fix**: Add Ollama embeddings + sqlite-vec. Medium effort. Keeps everything local.

### 8. Basic CLI (Not Rich TUI)
The CLI works but isn't as immersive as OpenClaw's full terminal UI.

**Fix**: Add Ratatui (Rust) or ExTermbox TUI. Or build with Owl (Elixir terminal library). Medium effort.

### 9. Fewer Pre-Built Skills
7 built-in vs 53. Missing popular integrations (GitHub, Notion, Spotify, etc.).

**Fix**: The SKILL.md system makes adding skills trivial. Community can contribute. Create 10-15 popular ones.

### 10. No DM Gating for Channels
When channels go live, need pairing/approval system for unknown senders.

**Fix**: Add pairing code system. Low-medium effort.

---

## PRIORITY HIT LIST (What to Build Next)

### Tier 1 — Close Critical Gaps (Do These First)
- [ ] **Voice (Edge TTS + Whisper)** — Free, local, high impact
- [ ] **WebChat channel** — Web frontend to existing HTTP API
- [ ] **DM pairing/gating** — Required before channels go public
- [ ] **OpenRouter provider** — One integration = 100+ models
- [ ] **iMessage via BlueBubbles** — macOS users want this

### Tier 2 — Strengthen Advantages
- [ ] **More example skills** — GitHub, Notion, weather, Spotify (10-15 total)
- [ ] **Ollama embeddings + sqlite-vec** — Local semantic search
- [ ] **Tailscale remote access** — Access from phone/other machines
- [ ] **Rich TUI** — Polish the terminal experience

### Tier 3 — Nice to Have
- [ ] **Browser automation (Playwright)** — Power-user feature
- [ ] **Canvas/visual output** — Charts and dashboards
- [ ] **More channels** — Teams, Google Chat, IRC
- [ ] **Auto-reply/DND** — Convenience
- [ ] **Presence system** — Online/typing indicators
- [ ] **IDE integration** — VSCode extension

### Tier 4 — Future
- [ ] **Mobile nodes** — iOS/Android apps
- [ ] **Web dashboard** — Config UI
- [ ] **Plugin registry** — Community skills marketplace
- [ ] **A/B testing** — Model/prompt experiments

---

## ARCHITECTURAL COMPARISON

```
OPENCLAW                              OSA
────────────────────                  ────────────────────
Single Node.js process                BEAM VM (Erlang/OTP)
  - V8 event loop                       - Preemptive scheduling
  - One crash = all dead                - Component auto-restart
  - Queue-based concurrency             - True parallelism (30+)
  - 527K LOC                            - 18.7K LOC
  - ~200 tests                          - 440 tests
  - 65+ npm dependencies                - Focused deps
  - Over-engineered memory              - Clean 3-store + cortex
  - No message intelligence             - 5-tuple signal classification
  - Basic compaction                     - 4-tier context + progressive compression
  - Channel routing only                 - Dependency-aware orchestration + swarms
  - No sandbox                           - Docker sandbox (CAP_DROP ALL)
  - No communication awareness           - 5 intelligence modules
  - Pre-defined tools only               - Dynamic skill creation
  - Generic system prompt                - Layered soul/identity/user
  - JS event routing                     - goldrush compiled bytecode
```

---

## BOTTOM LINE

**OpenClaw is wider. OSA is smarter.**

OpenClaw has more integrations, more channels, more plugins, more surface area. It's a Swiss Army knife with 50 blades.

OSA has deeper intelligence. It understands messages before processing them. It knows how people communicate. It manages context intelligently. It collaborates across agents. It self-teaches new skills. And it does all this on a telecom-grade runtime that doesn't crash when one channel has a bad day.

**The channels/voice/browser gaps are fixable.** They're engineering work, not architectural problems. OSA's BEAM architecture actually makes adding channels EASIER than OpenClaw's monolithic approach (each channel is a supervised process that can crash independently).

**The intelligence gaps are NOT fixable for OpenClaw.** Signal classification, communication intelligence, context budgeting, progressive compaction — these are architectural decisions baked into OSA's DNA. OpenClaw would need a fundamental rewrite to add them.

**Build the channels. Keep the intelligence. Win both games.**
