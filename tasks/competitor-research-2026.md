# AI Agent Framework & CLI Tool Competitive Research
> Date: 2026-02-27 | Source: Web research, Feb 2026

---

## 1. OpenClaw (formerly Clawdbot / Moltbot)

### What It Is
OpenClaw is a **free, open-source, autonomous personal AI agent** that runs as a local daemon on your machine. Created by Peter Steinberger (PSPDFKit founder) in November 2025 (originally as "Clawdbot"), it was renamed Moltbot then OpenClaw in January 2026. It uses messaging platforms (WhatsApp, Telegram, Discord, Signal, etc.) as its primary user interface rather than a traditional CLI or IDE. As of February 2026 it has **195K+ GitHub stars** and Steinberger announced he is joining OpenAI, with the project moving to an open-source foundation.

- **Language/Stack**: Node.js / TypeScript
- **License**: MIT
- **GitHub**: github.com/openclaw/openclaw

### Full Feature List

#### Core Architecture
- **Gateway daemon** (hub-and-spoke): persistent WebSocket server that routes messages between channels, agents, and LLMs
- **Agent Runtime**: assembles context from session history + memory, invokes model, executes tool calls, persists state
- **Heartbeat system**: scheduled agent wake-ups (default 30min) for proactive behavior without user prompting
- **Session management**: per-channel, per-conversation agent sessions

#### Channels & Integrations (50+)
WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Google Chat, Microsoft Teams, Matrix, Zalo, and 40+ more

#### Skills System
- **2,857+ skills** on ClawHub marketplace
- ~49 pre-built skills ship with the core
- Skills are **Markdown files** with YAML frontmatter + instructions + optional scripts
- Each skill is a directory: `skill.md` + reference files + executables
- Skills package API calls, database queries, document retrieval, workflows into reusable agent-invocable components

#### Tools & Capabilities
- File read/write, shell command execution
- Browser automation and control
- Email access and interaction
- Cron job scheduling
- Dozens of external service integrations

#### LLM Provider Support
- **Anthropic** (Claude)
- **OpenAI** (GPT-4o, GPT-5.2)
- **Google** (Gemini 3 Pro Preview) with API key rotation
- **Ollama** (local models)
- **DeepSeek**
- **Groq**
- **Mistral**
- **OpenRouter**
- **GitHub Copilot**
- **Hugging Face Inference**
- **MiniMax** (Anthropic-compatible API)
- **Any OpenAI-compatible API** as custom provider
- **vLLM** support
- **LMStudio** support
- Fallback chain configuration (primary -> secondary -> tertiary)

#### CLI Features (150+ commands)
- Gateway management (launchd/systemd/schtasks)
- `--json` output (line-delimited JSON)
- `--no-color` / `NO_COLOR=1` support
- OSC-8 hyperlinks in supported terminals
- Onboarding wizard
- `openclaw doctor` diagnostic command
- `openclaw status --usage` for API credit tracking across providers
- Channel setup commands (Telegram, WhatsApp, Discord, Google Chat, etc.)
- Skill management commands
- Memory management commands
- Cron and heartbeat management
- Workspace file management
- Slash commands

#### Memory System
- **Plain Markdown files** as source of truth on local filesystem
- Agents write to memory after every significant event
- Two agent-facing tools: `memory_search` (semantic recall) and `memory_get` (targeted read)
- **Hybrid search**: vector (0.7 weight) + text (0.3 weight) with optional MMR and temporal decay
- **SQLite-backed RAG**: chunks Markdown, generates embeddings, stores in local .sqlite
- Session transcripts auto-saved with LLM-generated slugs
- Auto-memory flush before context compaction
- Indexed and searchable across sessions

#### Multi-Agent / Swarm
- Multiple agent sessions via channels
- **Lobster**: built-in workflow engine (typed, local-first pipeline runtime)
- Deterministic execution with JSON data flow between steps
- Third-party: ClawSwarm (Swarms framework integration, multi-agent, compiles to Rust)
- Community multi-agent architectures documented

#### Security
- Docker-based sandboxing for tool execution
- Tool policy resolution and workspace containment
- Elevated mode for privileged operations
- Mandatory gateway authentication (CVE-2026-25253 patched)
- `OPENCLAW_GATEWAY_PASSWORD` required on all deployments

### Unique / Standout Features
1. **Messaging-first UX** (WhatsApp/Telegram/Discord as primary interface, not CLI/IDE)
2. **Heartbeat daemon** (proactive agent that wakes up on schedule and acts autonomously)
3. **195K GitHub stars in 66 days** (18x faster growth than Kubernetes)
4. **ClawHub marketplace** with 2,857+ community skills
5. **50+ messaging channel integrations**
6. **Local-first everything** (memory as Markdown on disk, SQLite for embeddings)
7. **Lobster workflow engine** (deterministic pipeline execution)

### Weaknesses / Gaps
- **Security concerns**: CVE-2026-25253 was critical RCE; skill repository lacked vetting (Cisco found data exfiltration in third-party skills)
- **No sandboxing by default**: gateway runs on host with full filesystem/network access; Docker sandbox is opt-in
- **Not a coding agent**: primarily a personal assistant/automation agent, not purpose-built for software engineering
- **Skill trust model**: community skills can contain prompt injection, malicious code
- **No IDE integration**: messaging-first means no VS Code / JetBrains integration
- **Node.js single-process**: in-memory command queue, no native clustering

---

## 2. NanoClaw

### What It Is
A **minimalist, security-first alternative to OpenClaw** created by Gavriel Cohen (ex-Wix, 7 years). Released January 31, 2026 under MIT license. Built on Anthropic's Claude Agent SDK.

- **Language/Stack**: TypeScript (~500 lines core, 15 source files)
- **License**: MIT
- **GitHub**: github.com/qwibitai/nanoclaw

### Key Features
- Single Node.js process
- **Container isolation** (Apple Container on macOS, Docker on Linux) -- agents can only access explicitly mounted directories
- WhatsApp integration, memory, scheduled jobs
- Agent Swarms (teams of agents collaborating in chat)
- Built directly on Anthropic's Agents SDK
- Entire codebase auditable in ~8 minutes

### Strengths
- Drastically better security model than OpenClaw (real container isolation vs. host-level access)
- Extremely small codebase (readable, auditable, forkable)
- Same core functionality as OpenClaw for personal assistant use cases

### Weaknesses
- Limited to Claude models (built on Anthropic SDK)
- Far fewer integrations and skills than OpenClaw
- Small community and ecosystem
- WhatsApp-focused (fewer channel options)

---

## 3. Aider

### What It Is
An **open-source AI pair programming tool** that runs in the terminal. Designed for editing existing codebases with LLMs. Created by Paul Gauthier.

- **Language/Stack**: Python
- **License**: Apache 2.0
- **GitHub**: github.com/Aider-AI/aider
- **Website**: aider.chat

### Key Features
- Repository-level agent for multi-file refactors and debugging
- 100+ coding language support
- Auto-stages and commits with descriptive messages
- Auto-runs linters and tests on generated code, fixes detected problems
- IDE integration via source file comments
- Image and web page context (screenshots, reference docs)
- Voice input support
- SOTA performance on SWE-Bench

### LLM Support
Claude 3.7 Sonnet, DeepSeek R1 & Chat V3, OpenAI o1/o3-mini/GPT-4o, plus nearly any LLM including local models

### Strengths
- Best-in-class SWE-Bench performance
- Git-native workflow (auto-commit, auto-test)
- Broad LLM compatibility
- Mature, well-documented, active community
- Pure terminal tool -- no IDE dependency

### Weaknesses
- No built-in multi-agent / swarm capabilities
- No persistent memory or learning system
- Terminal-only (no GUI, no IDE extension)
- No MCP support natively
- Single-agent architecture

---

## 4. Continue.dev

### What It Is
An **open-source AI coding assistant** that integrates into VS Code and JetBrains as an extension. Model-agnostic with chat, plan, and agent modes.

- **Language/Stack**: TypeScript
- **License**: Apache 2.0
- **GitHub**: github.com/continuedev/continue
- **Website**: continue.dev

### Key Features
- Three interaction modes: Chat, Plan (read-only sandbox), Agent (autonomous multi-file)
- Model-agnostic: connect to any LLM (local or cloud)
- `.continue/rules/` directory for team-shared AI behavior configuration
- MCP tool support (GitHub, Sentry, Snyk, Linear)
- Deployable: cloud, on-premise, or fully offline/air-gapped
- Tab autocomplete
- Code context awareness

### Strengths
- Deep IDE integration (VS Code + JetBrains)
- Team-friendly configuration sharing
- Model-agnostic (Ollama, OpenAI, Anthropic, etc.)
- Air-gapped/enterprise deployment support
- Free and open-source

### Weaknesses
- IDE-dependent (no standalone CLI agent)
- No persistent memory or learning
- No multi-agent / swarm capabilities
- Agent mode less mature than Cursor's
- Not a standalone coding agent -- requires IDE context

---

## 5. Cursor

### What It Is
A **commercial AI-first code editor** built on VS Code with deep AI integration. Not open-source. Created by Anysphere.

- **Language/Stack**: TypeScript (Electron/VS Code fork)
- **License**: Proprietary (free tier + paid plans)
- **Website**: cursor.com

### Key Features
- Full IDE rebuilt around AI (not just a plugin)
- Intelligent multi-line code completion with recent-change awareness
- Codebase-wide understanding and natural language querying
- Multi-file coherent editing
- **Cursor 2.0**: Own coding model (Composer), agent-centric interface
- **8 parallel agents** via git worktrees or remote machines
- **Plan Mode**: reads docs/rules, generates editable Markdown plan
- **Background Agents**: async task execution
- Built-in browser for UI verification
- Rules, Slash Commands, Hooks
- Model flexibility (OpenAI, Anthropic, Gemini, xAI)

### Strengths
- Best-in-class IDE + AI integration
- Parallel agent execution (up to 8)
- Plan mode with collaborative refinement
- Built-in browser for visual verification
- Enterprise features (billing groups, service accounts, security controls)
- Massive user base and active development

### Weaknesses
- **Proprietary / closed-source**
- Expensive at scale ($20/mo Pro, $40/mo Business)
- VS Code fork -- locked into that ecosystem
- No terminal-only / headless mode
- No self-hosting option
- No persistent memory across sessions

---

## 6. Cline (formerly Claude Dev)

### What It Is
An **open-source autonomous AI coding agent** for VS Code. Executes multi-step development tasks with human approval at each step.

- **Language/Stack**: TypeScript (VS Code extension)
- **License**: Apache 2.0
- **GitHub**: github.com/cline/cline
- **Website**: cline.bot

### Key Features
- Plan/Act modes for controlled autonomy
- File creation/editing, terminal command execution
- **Browser automation** via Claude's Computer Use (headless browser, click, fill forms, screenshot at each step)
- Timeline view for change tracking and rollback
- **MCP integration** for custom tool development
- Domain-specific agent building capability
- 5M+ developers

### LLM Support
OpenRouter, Anthropic, OpenAI, Google Gemini, AWS Bedrock, Azure, GCP Vertex, Ollama (local models)

### Strengths
- Human-in-the-loop approval at every step (safe)
- Browser automation with visual debugging
- MCP extensibility
- Broad LLM provider support
- Strong change tracking / rollback
- Large, active community (5M+ users)

### Weaknesses
- VS Code-only (no CLI, no JetBrains)
- Single-agent architecture (no multi-agent/swarm)
- No persistent memory or learning
- Can be slow due to approval requirements
- Resource-heavy in VS Code

---

## 7. OpenHands (formerly OpenDevin)

### What It Is
An **open-source platform for AI software development agents** that interact like human developers: writing code, using command line, browsing the web. Academic + industry collaboration.

- **Language/Stack**: Python
- **License**: MIT
- **GitHub**: github.com/OpenHands/OpenHands
- **Website**: openhands.dev

### Key Features
- Docker-sandboxed runtime (bash shell + web browser + IPython server)
- **Agent Hub**: 10+ implemented agents (CodeAct architecture as flagship)
- Hierarchical multi-agent with delegation primitives
- **15 evaluation benchmarks** built-in
- SDK: composable Python library for defining agents
- Cloud scaling: run locally or scale to 1000s of agents
- Web browsing and code editing specialists

### Performance
- SWE-bench Lite: 26% | HumanEvalFix: 79% | WebArena: 15% | GPQA: 53%

### Strengths
- True multi-agent with hierarchical delegation
- Docker sandboxing (security-first)
- Comprehensive evaluation framework (15 benchmarks)
- Scale from local to cloud (1000s of agents)
- Academic rigor (published papers)
- 2.1K+ contributions from 188+ contributors

### Weaknesses
- Lower SWE-bench scores than competitors
- Complex setup (Docker required)
- More research-oriented than production-ready
- No IDE integration
- No persistent memory across sessions
- Slower iteration than commercial tools

---

## 8. SWE-Agent

### What It Is
An **open-source AI agent** that transforms LLMs into software engineering agents capable of autonomously resolving GitHub issues. Created by Princeton NLP Group.

- **Language/Stack**: Python
- **License**: MIT
- **GitHub**: github.com/SWE-agent
- **Papers**: arxiv.org/abs/2405.15793

### Key Features
- Custom **Agent-Computer Interface (ACI)** for enhanced file browsing, editing, and test execution
- Repository navigation and code understanding
- Autonomous bug identification and fixing
- **Live-SWE-agent**: self-evolving agent that improves its own scaffold during runtime
- **mini-SWE-agent**: 100-line agent that still gets 65% on SWE-bench Verified

### Performance
- Claude Opus 4.5 + Live-SWE-agent: **79.2% on SWE-bench Verified** (SOTA for open-source)

### Strengths
- SOTA SWE-bench performance with Live-SWE-agent
- Self-evolving capability (unique -- agent improves its own tools at runtime)
- Clean, focused architecture
- Academic backing (Princeton NLP)
- mini-SWE-agent proves the architecture is elegant (100 lines, 65% benchmark)

### Weaknesses
- Research tool, not a developer product
- No IDE integration
- No CLI for interactive use
- No multi-agent orchestration
- No memory/learning persistence
- Focused solely on GitHub issue resolution

---

## 9. Devin (by Cognition AI)

### What It Is
A **commercial autonomous AI software engineer** -- the first to market with a "full engineer" positioning. Not open-source.

- **Language/Stack**: Proprietary (cloud-based)
- **License**: Proprietary (subscription)
- **Website**: devin.ai

### Key Features
- Complete toolkit: code editor, shell, web browser, full internet access
- Multi-step engineering tasks without supervision
- **Devin Wiki**: auto-generated software documentation
- **Devin Search**: interactive code Q&A engine
- **Devin 2.2** (Feb 2026): 3x faster startup, new lifecycle UI
- End-to-end testing via computer use (any Linux desktop app)
- Multiple parallel Devin instances
- Slack, Linear, Jira, GitHub, GitLab integration

### Strengths
- Most "complete" autonomous engineer product
- Deep integration with project management tools
- Parallel instance execution
- End-to-end testing with computer use
- Well-funded (Cognition AI)

### Weaknesses
- **Proprietary and expensive** (~$500/mo per seat)
- Cloud-only (no local execution)
- No open-source option
- Quality inconsistent on complex real-world tasks
- Can't inspect or modify the agent's internals
- Privacy concerns (code goes to Cognition's cloud)

---

## 10. Devon (open-source, by Entropy Research)

### What It Is
An **open-source AI pair programmer** inspired by Devin. Different from Devin (Cognition AI).

- **Language/Stack**: Python
- **License**: Apache 2.0
- **GitHub**: github.com/entropy-research/Devon

### Key Features
- Code editor, shell, web browser access
- Multi-step task execution
- Pair programming interaction model

### Strengths
- Open-source alternative to Devin
- Local execution capability

### Weaknesses
- Much less mature than Devin
- Smaller community
- Limited documentation
- Development appears to have slowed

---

## 11. Mentat (by Abante AI)

### What It Is
An **open-source AI coding assistant** for the command line, focused on multi-file coordination and codebase understanding.

- **Language/Stack**: Python
- **License**: Apache 2.0
- **GitHub**: github.com/AbanteAI/mentat
- **Website**: mentat.ai

### Key Features
- Direct CLI interaction (no copy-paste workflow)
- Multi-file, multi-location coordinated edits
- Context-aware code generation
- **Auto Context**: RAG-based relevant snippet selection
- Git integration
- Multi-language support

### Strengths
- Good multi-file coordination
- RAG-based context retrieval
- CLI-native workflow
- Understands existing code context

### Weaknesses
- Development has slowed significantly (last major updates in 2024)
- Limited LLM support (primarily GPT-4)
- No multi-agent capabilities
- No memory/learning system
- Small community compared to Aider
- No IDE integration
- Appears to be in maintenance mode

---

## 12. AutoCodeRover

### What It Is
An **academic autonomous program improvement system** that combines LLMs with AST-aware code search to solve GitHub issues.

- **Language/Stack**: Python
- **License**: Open-source
- **Papers**: arxiv.org/abs/2404.05427 (ISSTA 2024)

### Key Features
- Two-stage pipeline: context retrieval + patch generation
- **AST-aware search** (searches methods/classes in abstract syntax tree, not plain text)
- Autonomous GitHub issue resolution
- Average cost: $0.43 per issue fix
- Average time: ~4 minutes per fix (vs. 2.68 days for human developers)

### Performance
- SWE-bench: 16% | SWE-bench Lite: 22%

### Strengths
- AST-aware code search (unique architectural insight)
- Extremely cost-effective ($0.43/fix)
- Fast (4 min average)
- Academic rigor

### Weaknesses
- Research prototype, not a developer tool
- Low SWE-bench scores by 2026 standards
- No interactive use
- No IDE integration
- No multi-agent capabilities
- No memory or learning

---

## 13. Goose (by Block / Square)

### What It Is
An **open-source AI agent framework** by Block (Jack Dorsey's company). Runs locally, extensible via MCP, designed for developers.

- **Language/Stack**: Rust
- **License**: Apache 2.0
- **GitHub**: github.com/block/goose
- **Website**: block.github.io/goose

### Key Features
- Build projects from scratch, write/execute code, debug, orchestrate workflows
- **First-class MCP support** (1,700+ extensions)
- CLI + desktop app (not IDE-locked)
- Named sessions and chat history
- **Subagents** for parallel task execution
- **Recipes**: structured workflow definitions
- **Skills** for custom context injection
- IDE integration (connects to your IDE, runs commands)
- Local-first, private data

### Adoption
- 60% of Block workforce uses Goose weekly
- 50-75% reported development time savings

### Strengths
- Built in Rust (fast, efficient)
- Massive MCP ecosystem (1,700+ extensions)
- Real production adoption at scale (Block)
- CLI + desktop app flexibility
- Subagent parallelism
- Recipe system for repeatable workflows
- Backed by a major tech company

### Weaknesses
- Relatively new (less battle-tested than Aider)
- Documentation still maturing
- No persistent memory/learning system
- Limited multi-agent orchestration (subagents only, no swarms)
- Block-centric development priorities

---

## 14. Codex CLI (by OpenAI)

### What It Is
OpenAI's **open-source terminal coding agent**, built in Rust. Uses GPT-5.2-Codex model.

- **Language/Stack**: Rust
- **License**: Apache 2.0
- **GitHub**: github.com/openai/codex
- **Website**: developers.openai.com/codex/cli

### Key Features
- Local terminal execution (read, change, run code)
- **Three approval modes**: read-only, auto (workspace-scoped), full access
- **Multi-agent collaboration** (experimental, via config.toml)
- Code review by separate Codex agent
- Web search integration
- **MCP support** for third-party tools
- Image attachment (screenshots, wireframes, diagrams)
- Voice transcription (hold spacebar)
- To-do list progress tracking
- GPT-5.2-Codex optimized for code generation and repo-scale reasoning

### Future Roadmap
- **Codex Jobs**: cloud-based automation on triggers (SaaS devops)
- Windows support (late 2026)

### Strengths
- Built in Rust (fast)
- OpenAI backing and model optimization
- Multi-agent collaboration (experimental)
- Voice input
- Image context support
- MCP extensibility

### Weaknesses
- **OpenAI models only** (no Anthropic, no local models)
- Relatively new and still evolving
- Multi-agent is experimental
- No persistent memory
- No Windows support yet
- Tied to OpenAI ecosystem

---

## 15. Amp (by Sourcegraph)

### What It Is
A **coding agent built for teams** by Sourcegraph, with deep code intelligence and no token constraints.

- **Language/Stack**: TypeScript
- **License**: Proprietary (free tier available)
- **Website**: ampcode.com / sourcegraph.com/amp

### Key Features
- **Deep mode**: autonomous research using extended reasoning
- **Composable tool system**: code review agent, Painter (image generation), Walkthrough (annotated diagrams)
- **Sub-agents**: Oracle (code analysis) and Librarian (external library analysis)
- AGENT.md project files for codebase structure awareness
- Dynamic thinking budget adjustment ("think hard" prompt)
- File change tracking across conversations
- VS Code, JetBrains (via CLI), Neovim, terminal UI support

### Pricing
- Free tier (ad-supported, up to $10/day)
- Pay-as-you-go with no markup

### Strengths
- Sourcegraph's code intelligence (massive codebase understanding)
- Sub-agent architecture (Oracle, Librarian)
- Team-oriented design
- Multi-IDE support including terminal
- No token constraints
- Free tier is generous

### Weaknesses
- Newer entrant (less proven)
- Proprietary
- Primarily Claude-powered (Sonnet 4)
- No self-hosting
- Limited multi-agent orchestration compared to full swarm systems
- No persistent memory/learning

---

## Comparative Matrix

| Tool | Type | Open Source | Language | CLI | IDE | Multi-Agent | Memory | MCP | LLM Agnostic |
|------|------|-----------|----------|-----|-----|-------------|--------|-----|---------------|
| **OpenClaw** | Personal agent | Yes (MIT) | TS/Node | Yes | No | Partial | Yes (RAG) | No | Yes (15+) |
| **NanoClaw** | Personal agent | Yes (MIT) | TS/Node | Yes | No | Yes (swarms) | Yes | No | No (Claude) |
| **Aider** | Coding agent | Yes (Apache) | Python | Yes | Partial | No | No | No | Yes |
| **Continue.dev** | IDE assistant | Yes (Apache) | TS | No | Yes | No | No | Yes | Yes |
| **Cursor** | AI IDE | No | TS | Partial | Yes | Yes (8x) | No | No | Yes |
| **Cline** | Coding agent | Yes (Apache) | TS | No | Yes (VS Code) | No | No | Yes | Yes |
| **OpenHands** | Agent platform | Yes (MIT) | Python | Yes | No | Yes (hierarchy) | No | No | Yes |
| **SWE-Agent** | Research agent | Yes (MIT) | Python | Yes | No | No | No | No | Yes |
| **Devin** | AI engineer | No | Proprietary | No | Web | Yes (parallel) | No | No | No |
| **Devon** | Coding agent | Yes (Apache) | Python | Yes | No | No | No | No | Partial |
| **Mentat** | Coding agent | Yes (Apache) | Python | Yes | No | No | Partial (RAG) | No | Partial |
| **AutoCodeRover** | Research agent | Yes | Python | Yes | No | No | No | No | Yes |
| **Goose** | Agent framework | Yes (Apache) | Rust | Yes | Partial | Yes (subagents) | No | Yes (1700+) | Yes |
| **Codex CLI** | Coding agent | Yes (Apache) | Rust | Yes | No | Experimental | No | Yes | No (OpenAI) |
| **Amp** | Coding agent | No | TS | Yes | Yes | Yes (sub-agents) | No | No | Partial |

---

## Key Takeaways for OSA

### What OpenClaw Does That Others Don't
1. **Messaging-first UX** (50+ channels) -- no one else has this
2. **Heartbeat daemon** for proactive autonomous behavior
3. **Skill marketplace** (2,857+ community skills)
4. **Local-first memory with hybrid RAG** (Markdown + SQLite + vector search)

### Gaps in the Market (Opportunities for OSA)
1. **No tool combines**: multi-agent swarm + persistent memory/learning + CLI coding agent + LLM-agnostic + local-first
2. **Memory/learning is universally weak** -- OpenClaw has the best (Markdown + RAG) but no self-improvement loop
3. **Signal Theory / output quality framework** -- no competitor has anything like this
4. **Elixir/OTP as runtime** -- no competitor uses actor model / fault-tolerant architecture
5. **Tier-aware model routing** -- only Cursor (8 parallel agents) comes close to sophistication
6. **Hook pipeline with middleware** -- only OpenClaw has something comparable
7. **Budget-per-agent token management** -- no competitor has this

### Strongest Competitors by Category
- **CLI Coding Agent**: Aider (SOTA SWE-bench, mature, broad LLM support)
- **IDE Agent**: Cursor (parallel agents, plan mode, most polished UX)
- **Open-Source Agent Framework**: Goose (Rust, MCP, production-proven at Block)
- **Personal AI Agent**: OpenClaw (most features, largest community)
- **Research Agent**: SWE-Agent + Live-SWE-agent (79.2% SWE-bench, self-evolving)
- **Multi-Agent Platform**: OpenHands (hierarchical delegation, evaluation framework)

### Architecture Patterns Worth Noting
- **OpenClaw**: Gateway daemon + Markdown memory + skill marketplace
- **Goose**: Rust + MCP-first extensibility + recipes
- **Cursor**: Git worktree isolation for parallel agents
- **SWE-Agent**: Self-evolving scaffold (agent improves its own tools)
- **OpenHands**: Docker sandbox + agent hub + hierarchical delegation
- **Codex CLI**: Approval modes (read-only / auto / full)

---

## Sources

### OpenClaw
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [OpenClaw Wikipedia](https://en.wikipedia.org/wiki/OpenClaw)
- [DigitalOcean: What is OpenClaw](https://www.digitalocean.com/resources/articles/what-is-openclaw)
- [Milvus: OpenClaw Complete Guide](https://milvus.io/blog/openclaw-formerly-clawdbot-moltbot-explained-a-complete-guide-to-the-autonomous-ai-agent.md)
- [CNBC: OpenClaw Rise](https://www.cnbc.com/2026/02/02/openclaw-open-source-ai-agent-rise-controversy-clawdbot-moltbot-moltbook.html)
- [Context Studios: Running OpenClaw in Production](https://www.contextstudios.ai/blog/the-complete-openclaw-guide-how-we-run-an-ai-agent-in-production-2026)
- [OpenClaw Architecture Deep Dive](https://ppaolo.substack.com/p/openclaw-system-architecture-overview)
- [DigitalOcean: OpenClaw Skills](https://www.digitalocean.com/resources/articles/what-are-openclaw-skills)
- [Valletta Software: OpenClaw 2026 Guide](https://vallettasoftware.com/blog/post/openclaw-2026-guide)
- [OpenClaw Docs: Memory](https://docs.openclaw.ai/concepts/memory)
- [OpenClaw Docs: Model Providers](https://docs.openclaw.ai/concepts/model-providers)
- [OpenClaw Docs: CLI Reference](https://docs.openclaw.ai/cli)
- [OpenClaw Docs: Heartbeat](https://docs.openclaw.ai/gateway/heartbeat)
- [OpenClaw Docs: Security](https://docs.openclaw.ai/gateway/security)
- [CrowdStrike: OpenClaw Security Analysis](https://www.crowdstrike.com/en-us/blog/what-security-teams-need-to-know-about-openclaw-ai-super-agent/)
- [Auth0: Securing OpenClaw](https://auth0.com/blog/five-step-guide-securing-moltbot-ai-agent/)
- [Milvus: memsearch (extracted memory system)](https://milvus.io/blog/we-extracted-openclaws-memory-system-and-opensourced-it-memsearch.md)

### NanoClaw
- [NanoClaw GitHub](https://github.com/qwibitai/nanoclaw)
- [The New Stack: NanoClaw Minimalist Agents](https://thenewstack.io/nanoclaw-minimalist-ai-agents/)
- [VentureBeat: NanoClaw Security](https://venturebeat.com/orchestration/nanoclaw-solves-one-of-openclaws-biggest-security-issues-and-its-already)
- [NanoClaw Website](https://nanoclaw.dev/)

### Aider
- [Aider GitHub](https://github.com/Aider-AI/aider)
- [Aider Website](https://aider.chat/)
- [Faros AI: Best AI Coding Agents 2026](https://www.faros.ai/blog/best-ai-coding-agents-2026)

### Continue.dev
- [Continue.dev Website](https://www.continue.dev/)
- [Continue.dev Docs](https://docs.continue.dev/)
- [Continue VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=Continue.continue)

### Cursor
- [Cursor Features](https://cursor.com/features)
- [Cursor Website](https://cursor.com/)
- [NxCode: Cursor Review 2026](https://www.nxcode.io/resources/news/cursor-review-2026)
- [Cursor Wikipedia](https://en.wikipedia.org/wiki/Cursor_(code_editor))

### Cline
- [Cline GitHub](https://github.com/cline/cline)
- [Cline Website](https://cline.bot/)
- [VibeCoding: Cline Review 2026](https://vibecoding.app/blog/cline-review-2026)

### OpenHands
- [OpenHands GitHub](https://github.com/OpenHands/OpenHands)
- [OpenHands Website](https://openhands.dev/)
- [OpenHands Paper](https://arxiv.org/abs/2407.16741)

### SWE-Agent
- [SWE-Agent GitHub](https://github.com/SWE-agent)
- [SWE-Agent Paper](https://arxiv.org/abs/2405.15793)
- [Live-SWE-agent Paper](https://arxiv.org/abs/2511.13646)

### Devin
- [Devin Website](https://devin.ai/)
- [Cognition AI](https://cognition.ai/)
- [Devin Wikipedia](https://en.wikipedia.org/wiki/Devin_AI)
- [Cognition: Devin 2025 Performance Review](https://cognition.ai/blog/devin-annual-performance-review-2025)

### Devon
- [Devon GitHub](https://github.com/entropy-research/Devon)

### Mentat
- [Mentat GitHub](https://github.com/AbanteAI/mentat)
- [Mentat Website](https://mentat.ai/)

### AutoCodeRover
- [AutoCodeRover Paper](https://arxiv.org/abs/2404.05427)

### Goose
- [Goose GitHub](https://github.com/block/goose)
- [Goose Website](https://block.github.io/goose/)
- [Block Announcement](https://block.xyz/inside/block-open-source-introduces-codename-goose)
- [All Things Open: Meet Goose](https://allthingsopen.org/articles/meet-goose-open-source-ai-agent)

### Codex CLI
- [Codex CLI GitHub](https://github.com/openai/codex)
- [Codex CLI Docs](https://developers.openai.com/codex/cli/)
- [Codex CLI Features](https://developers.openai.com/codex/cli/features/)
- [OpenAI: Introducing Codex](https://openai.com/index/introducing-codex/)

### Amp
- [Amp Website](https://ampcode.com/)
- [Sourcegraph Amp](https://sourcegraph.com/amp)
- [Second Talent: Amp Review 2026](https://www.secondtalent.com/resources/amp-ai-review/)
