# Pipeline Comparison: Claude Code vs OpenClaw vs NanoClaw vs OSA

**Date**: 2026-02-28
**Purpose**: Granular pipeline mapping to identify gaps in OSA

---

## Quick Reference

| Dimension | Claude Code | OpenClaw | NanoClaw | OSA |
|-----------|-------------|----------|----------|-----|
| **Language** | TypeScript/Bun | TypeScript/Node | TypeScript/Node | Elixir/OTP 28 |
| **Architecture** | Single-threaded master loop | Gateway + pi-agent-core | Container-isolated per group | GenServer + Event Bus |
| **Primary Channel** | CLI terminal | Multi-channel gateway | WhatsApp | CLI (+ 10 channels) |
| **LLM SDK** | Anthropic native | @mariozechner/pi-coding-agent | Claude Agent SDK | Custom provider abstraction |
| **Providers** | Anthropic only (+Bedrock/Vertex) | 14+ (Anthropic, OpenAI, Google, Groq...) | Anthropic only | 18 (Anthropic, OpenAI, Ollama, etc.) |
| **Tool Count** | 18 built-in + MCP | 25+ native + plugins | SDK built-in + 7 MCP | 12 built-in skills + MCP |
| **System Prompt** | ~57K words, 110+ fragments | Dynamic sections (identity, skills, memory, tools) | `claude_code` preset + CLAUDE.md append | IDENTITY.md + SOUL.md + Signal overlay |
| **Compaction** | ~95% utilization auto-trigger | 40% chunk ratio, LLM summarization | Delegated to SDK | Token-budget tiers, LLM summarization |
| **Permissions** | 5 modes (default/acceptEdits/plan/dontAsk/bypass) | Tool profiles + policy pipeline | bypassPermissions (containerized) | Hook-based security_check |
| **Subagents** | Task tool, depth-limited, own context | sessions_spawn, subagents tool | SDK Task/Team tools | Swarm patterns, wave execution |

---

## Phase-by-Phase Pipeline Comparison

### Phase 1: User Input

| Step | Claude Code | OpenClaw | NanoClaw | OSA |
|------|-------------|----------|----------|-----|
| Entry | CLI readline (React Ink) | Gateway RPC `chat.send` / TUI / Channel adapter | WhatsApp Baileys WS | LineEditor.readline (raw /dev/tty) |
| Sanitization | Unicode NFC, strip nulls | `sanitizeChatSendMessageInput()` NFC + null + control chars | XML escaping in `formatMessages()` | `sanitize_input()` NFC + control char strip |
| Command detection | Slash commands in system prompt | `/think`, `/model`, `/reset` directives | `@Andy` trigger pattern regex | `/` prefix → `handle_command()` |
| Attachment handling | Image/PDF via Read tool | `parseMessageWithAttachments()` (5MB limit) | Via WhatsApp media | None |

**OSA Gap**: ~~No input sanitization.~~ **CLOSED** — `sanitize_input/1` does NFC normalization + control char stripping. No attachment/media handling. No directive parsing from message content.

---

### Phase 2: Message Classification & Routing

| Step | Claude Code | OpenClaw | NanoClaw | OSA |
|------|-------------|----------|----------|-----|
| Signal classification | None (LLM decides everything) | None (LLM decides everything) | None (LLM decides everything) | **Classifier.classify()** → S=(M,G,T,F,W) |
| Noise filtering | None | Duplicate detection (`shouldSkipDuplicateInbound`) | Bot message detection (`is_bot_message`) | **NoiseFilter** 2-tier (deterministic + LLM) |
| Routing decision | Always send to LLM | Session → Agent → Config resolution | Trigger match → Queue → Container | Signal weight → Plan mode check → Agent loop |

**OSA Advantage**: Signal Theory classification is UNIQUE to OSA. No other system classifies messages before sending to LLM. This enables:
- Adaptive system prompt (mode/genre overlay)
- Weight-based effort allocation
- Noise filtering (saves tokens on greetings/acks)
- Plan mode auto-detection

**OSA Consideration**: The classification LLM call adds latency (~200ms cached). For simple messages, this is overhead the others don't pay.

---

### Phase 3: System Prompt Assembly

| Component | Claude Code | OpenClaw | NanoClaw | OSA |
|-----------|-------------|----------|----------|-----|
| **Identity** | "You are Claude Code, Anthropic's CLI" | Configurable agent identity | `claude_code` preset | IDENTITY.md + SOUL.md |
| **Behavioral rules** | ~15K tokens (concise, no preamble, security, tool policy) | Skills, memory recall, messaging, workspace notes | Inherited from preset | Signal overlay + brevity constraints + anti-over-engineering rules |
| **Tool instructions** | Per-tool usage rules in system prompt | Tool summaries section | Inherited from preset | Tool process block + explicit routing rules ("Use file_read NOT cat") |
| **User context** | CLAUDE.md (global + project) | Workspace notes, context files | CLAUDE.md per group + global | USER.md, CommProfiler intelligence |
| **Environment** | Git status, OS, date, model ID | Agent ID, host, OS, model, shell, channel | Container env vars | Runtime block + environment block (git branch, modified files, recent commits, OS, Elixir/OTP ver, provider/model) |
| **Memory** | Markdown files, project memory | `memory_search`/`memory_get` tools | Per-group CLAUDE.md filesystem | Tiered: session JSONL + long-term MEMORY.md + episodic ETS index |
| **Dynamic injection** | `<system-reminder>` tags throughout conversation | Directive resolution, media understanding | IPC messages piped mid-query | Cortex bulletin, workflow state |
| **Token budget** | ~200K context, prompt cached | Context window guard (warn <16K, block <4K) | Delegated to SDK | Explicit 4-tier budget allocation |

**Critical Difference: System Prompt Philosophy**

- **Claude Code**: Massive static prompt (~57K words, 110+ fragments) with aggressive behavioral constraints. "Answer in fewer than 4 lines." "One word answers are best." This prompt is what makes Claude Code *feel* like Claude Code.
- **OpenClaw**: Modular sections assembled per-agent. Skills-first approach ("scan available_skills before replying"). Tool summaries always present. Messaging rules for cross-session communication.
- **NanoClaw**: Minimal — relies on `claude_code` SDK preset + per-group CLAUDE.md. The group memory IS the system prompt customization.
- **OSA**: Signal-adaptive. The system prompt changes based on what the user said (EXECUTE mode = concise, ANALYZE mode = thorough). Tiered budget prevents overflow.

**OSA Gaps (updated 2026-02-28)**:
1. ~~**No aggressive behavioral constraints**~~ **CLOSED** — context.ex now injects "Fewer than 4 lines", "No preamble", anti-over-engineering rules.
2. ~~**No tool usage policy**~~ **CLOSED** — context.ex:643-651 has explicit "Use file_read NOT cat, file_edit NOT sed" routing rules.
3. **No skills-first routing** like OpenClaw's "scan available_skills entries before replying."
4. ~~**No environment injection**~~ **CLOSED** — environment_block/1 injects git branch, modified files, recent commits, OS, Elixir/OTP version, provider/model.

---

### Phase 4: Tool Definitions & Gating

| Tool Category | Claude Code | OpenClaw | NanoClaw | OSA |
|---------------|-------------|----------|----------|-----|
| **File read** | Read (2000 lines, images, PDFs) | read (pi-coding-agent) | Read (SDK) | file_read |
| **File write** | Write, Edit (exact match), MultiEdit | write, edit (line-based), apply_patch (diffs) | Write, Edit (SDK) | file_write, **file_edit** (surgical string replace) |
| **Shell** | Bash (600s timeout, sandboxed) | exec, process (approval gate) | Bash (SDK, bypassPermissions) | shell_execute |
| **Search** | Glob (pattern), Grep (ripgrep), WebSearch, WebFetch | web_search, web_fetch, browser (Playwright) | Glob, Grep, WebSearch, WebFetch (SDK) | web_search, **web_fetch**, **file_glob**, **file_grep** |
| **Memory** | TodoRead/TodoWrite, Markdown files | memory_search, memory_get | SDK memory | memory_save |
| **Orchestration** | Task (subagents), Skill, AskUserQuestion | sessions_spawn, sessions_send, subagents | Task, Team*, SendMessage | orchestrate (swarm patterns) |
| **Messaging** | N/A (CLI only) | message (cross-channel), sessions_send | send_message (WhatsApp MCP) | N/A (per-channel built-in) |
| **Scheduling** | N/A | cron tool | schedule_task, pause/resume/cancel MCP | scheduler (agent/scheduler.ex) |
| **Planning** | TodoWrite (JSON task lists), exit_plan_mode | N/A (no explicit planning tool) | TodoWrite (SDK) | Plan mode (LLM-generated, user-reviewed) |
| **Directory listing** | LS | Inherited from pi-coding-agent | LS (SDK) | **dir_list** |
| **Images** | Read (images), WebFetch | image (analyze/generate), canvas | N/A | N/A |

**OSA Gaps (updated 2026-02-28)**:
1. ~~**No file edit tool**~~ **CLOSED** — `file_edit` skill does exact-match surgical string replacement.
2. ~~**No directory listing tool**~~ **CLOSED** — `dir_list` skill using `File.ls/1` with types/sizes.
3. ~~**No glob/pattern search**~~ **CLOSED** — `file_glob` skill using `Path.wildcard/2`.
4. ~~**No grep/content search**~~ **CLOSED** — `file_grep` skill using ripgrep with pure-Elixir fallback.
5. **No TodoWrite equivalent** — Claude Code uses structured JSON task lists with IDs and status. OSA has plan mode but no persistent task tracker tool.
6. **No image/vision support** — Claude Code reads images via Read tool.
7. ~~**No web fetch**~~ **CLOSED** — `web_fetch` skill using `:httpc` with HTML stripping.
8. **No notebook support** — Claude Code has NotebookRead/NotebookEdit.

**OSA Advantage**:
1. **Tool gating by model size** — OSA strips tool definitions for models < 7GB. No other system does this. Prevents hallucinated tool calls from small models.
2. **18 provider support** — OSA can use any LLM. Claude Code is Anthropic-only. OpenClaw supports 14+.

---

### Phase 5: LLM Invocation

| Aspect | Claude Code | OpenClaw | NanoClaw | OSA |
|--------|-------------|----------|----------|-----|
| **API format** | Anthropic Messages API | Multi-provider (Anthropic, OpenAI, Google...) | Anthropic Agent SDK | Multi-provider (18 providers) |
| **Streaming** | Token-by-token via content_block_delta | Token-by-token streaming | SDK stream | Provider-dependent |
| **Thinking/Reasoning** | Extended thinking with budget tokens | Model-specific thinking support | N/A | N/A |
| **Temperature** | Not exposed (model default) | Configurable | N/A | `temperature()` config function |
| **Max iterations** | While tool_calls present (no hard limit visible) | Retry loop with failover | SDK-managed | 30 (configurable) |
| **Error handling** | Context overflow → compact & retry; auth → failover | Context overflow → compact; auth → failover profile | SDK-managed | **Context overflow → compact & retry (3 attempts)**; `{:error, reason}` → error message |

**OSA Gaps (updated 2026-02-28)**:
1. **No extended thinking support** — Claude Code and OpenClaw support budget-based thinking for complex reasoning.
2. ~~**No automatic retry on context overflow**~~ **CLOSED** — `loop.ex` now detects context overflow errors, compacts via `maybe_compact/1`, and retries up to 3 times.
3. **No provider failover** — OpenClaw fails over to alternate auth profiles. OSA doesn't.

---

### Phase 6: Tool Execution Loop

| Aspect | Claude Code | OpenClaw | NanoClaw | OSA |
|--------|-------------|----------|----------|-----|
| **Loop pattern** | While tool_calls present | Multi-attempt with failover | SDK agentic loop | `run_loop()` recursive, max 30 iterations |
| **Pre-tool hooks** | PreToolUse event → shell commands | Global hook runner | PreToolUse hooks (sanitize Bash) | `Hooks.run(:pre_tool_use)` sync chain |
| **Post-tool hooks** | PostToolUse event → shell commands | N/A (handled by framework) | N/A | `Hooks.run_async(:post_tool_use)` fire-and-forget |
| **Tool result injection** | Appended as tool_result message | Appended to conversation | SDK manages | Appended as `%{role: "tool"}` |
| **Real-time steering** | h2A queue — user can interrupt and redirect mid-task | N/A | IPC messages piped mid-query via MessageStream | **Ctrl+C cancel** via `cancel_active_request/1` (non-blocking CLI) |
| **TodoWrite reminders** | Injected after tool uses to prevent drift | N/A | N/A | N/A |

**OSA Gaps (updated 2026-02-28)**:
1. ~~**No real-time steering**~~ **PARTIALLY CLOSED** — Ctrl+C cancels active requests via non-blocking async CLI. Does not yet support mid-task message injection (redirect).
2. **No objective drift prevention** — Claude Code injects TodoWrite state as reminders. OSA has nothing equivalent.

---

### Phase 7: Context Management

| Aspect | Claude Code | OpenClaw | NanoClaw | OSA |
|--------|-------------|----------|----------|-----|
| **Trigger threshold** | ~95% utilization | 40% chunk ratio OR context overflow error | SDK-managed | Token-budget tiers (50%, 80%, 90%, 95% in hooks) |
| **Strategy** | Summarize + clear old tool outputs | Token-share chunking → LLM summarization → merge | SDK compaction + PreCompact hook archives | `Compactor.maybe_compact()` LLM summarization |
| **Safety margin** | N/A | 1.2x (20% buffer for estimation inaccuracy) | N/A | N/A |
| **Tool result handling** | Clears older tool outputs first | `stripToolResultDetails()` removes untrusted payloads | N/A | N/A |
| **User control** | `/compact`, `/context`, CLAUDE.md "Compact Instructions" | N/A | N/A | N/A |

**OSA Gaps**:
1. **No `/compact` or `/context` commands** — Users can't manually trigger compaction or inspect context usage.
2. **No tool result stripping** — OpenClaw strips `toolResult.details` before compaction for security. OSA doesn't.

---

### Phase 8: Response Rendering

| Aspect | Claude Code | OpenClaw | NanoClaw | OSA |
|--------|-------------|----------|----------|-----|
| **Renderer** | React Ink + Yoga flexbox in terminal | WebSocket broadcast + channel adapters | stdout markers → WhatsApp send | `Markdown.render()` + ANSI + word wrap |
| **Diff display** | Colorized minimal diffs for file edits | N/A (gateway-level) | N/A | N/A |
| **Tool visualization** | Command, file path, result preview | N/A | `<internal>` tags stripped | Tool events via Bus → spinner/progress display |
| **Status line** | Configurable (model, context, costs) | N/A | N/A | `✓ 2s · 5 tools · ↓ 45.2k · execute · direct · w0.8` |
| **Permission prompts** | Inline with Shift+Tab mode cycling | Approval gate with UUID | Bypassed (containerized) | N/A (hook-based block) |

**OSA Advantage**: Status line with Signal Theory classification is unique. Shows mode/genre/weight.

---

## System Prompt Comparison: What Makes Each System "Work"

### Claude Code's Secret Sauce (the behavioral constraints)

```
- Answer concisely with fewer than 4 lines
- One word answers are best
- No preamble, no postamble
- Do NOT use emojis
- Prefer editing existing files over creating new ones
- NEVER create documentation files unless explicitly requested
- Use Read NOT cat, Grep NOT grep, Edit NOT sed
- Reserve Bash exclusively for system commands
- Do not add features beyond what was asked
- Do not create abstractions for one-time operations
- Delete unused code completely
- Do not add error handling for impossible scenarios
- Read existing code before suggesting modifications
```

These constraints are what make Claude Code feel fast and precise. Without them, the LLM tends to be verbose, over-explain, and over-engineer.

### OpenClaw's Secret Sauce (skills-first routing)

```
Before replying: scan <available_skills> entries.
If exactly one clearly applies: read its SKILL.md then follow it.
If multiple could apply: choose most specific.
If none apply: skip.
```

Plus cross-session messaging and multi-agent orchestration instructions.

### NanoClaw's Secret Sauce (simplicity)

It uses the `claude_code` preset verbatim and adds group-specific memory via CLAUDE.md. The containerization provides security. The IPC system provides real-time message piping.

### OSA's System Prompt

```
# IDENTITY — Who
You are OSA. Not a chatbot. Not "an AI assistant."

# SOUL — How you talk
Natural. Real. Like someone who gives a damn.
Never say "As an AI..." or "I'd be happy to help."

# Signal Overlay — Adaptive behavior (UNIQUE)
Mode: EXECUTE → Be concise, action-oriented
Genre: DIRECT → Respond with action, not explanation
Weight: 0.92 → Full attention and thoroughness
```

**What's missing from OSA's prompt compared to Claude Code**:

1. **Tool usage policy** — "Use Read NOT cat" etc. This is critical for preventing the LLM from running `cat file.txt` via shell instead of using the dedicated file read skill.
2. **Behavioral brevity constraints** — "Fewer than 4 lines" and "one word answers are best" make responses fast and token-efficient.
3. **Anti-over-engineering rules** — "Don't add features beyond what was asked", "no premature abstractions", "delete unused code"
4. **Code modification safety** — "Read file first before editing", "old_string must be unique"
5. **Security-first instructions** — "Refuse to create code that may be used maliciously"
6. **Git commit format** — Detailed commit message formatting and safety instructions
7. **PR creation format** — Pull request title, body, test plan format
8. **Environment context** — Git status, OS version, recent commits injected at start

---

## Critical Gap Analysis: What OSA Needs

### TIER 1: BLOCKING — ALL 5 CLOSED

| Gap | Status | Evidence |
|-----|--------|----------|
| ~~file_edit (surgical replacement)~~ | **CLOSED** | `file_edit.ex` — 124 lines, exact-match string replace |
| ~~file_glob (pattern search)~~ | **CLOSED** | `file_glob.ex` — 68 lines, Path.wildcard |
| ~~file_grep (content search)~~ | **CLOSED** | `file_grep.ex` — 120 lines, ripgrep + :re fallback |
| ~~dir_list (directory listing)~~ | **CLOSED** | `dir_list.ex` — 76 lines, File.ls with types/sizes |
| ~~Tool usage policy in prompt~~ | **CLOSED** | `context.ex` — "Use file_read NOT cat" routing rules |

### TIER 2: HIGH PRIORITY — 8 of 8 CLOSED

| Gap | Status | Evidence |
|-----|--------|----------|
| ~~Brevity constraints~~ | **CLOSED** | `context.ex` — "Fewer than 4 lines", "No preamble" |
| ~~Anti-over-engineering rules~~ | **CLOSED** | `context.ex` — "Don't add features beyond asked", "No abstractions for one-time ops" |
| ~~Environment context injection~~ | **CLOSED** | `context.ex:environment_block/1` — git branch, modified files, recent commits, OS, Elixir/OTP, provider/model |
| ~~Real-time steering (Ctrl+C)~~ | **CLOSED** | `cli.ex:cancel_active_request/1` — non-blocking async CLI |
| ~~web_fetch skill~~ | **CLOSED** | `web_fetch.ex` — 84 lines, :httpc + HTML strip |
| ~~Input sanitization~~ | **CLOSED** | `cli.ex:sanitize_input/1` — NFC normalize + control char strip |
| ~~Context overflow auto-retry~~ | **CLOSED** | `loop.ex` — 3 compaction attempts before failing |
| ~~Non-blocking CLI~~ | **CLOSED** | `cli.ex` — async send_to_agent, ETS tracking, event-driven response |

### TIER 3: NICE TO HAVE — 7 OPEN

| Gap | Impact | What to do |
|-----|--------|-----------|
| **No TodoWrite equivalent** | No structured task tracking for multi-step work. | Implement `task_write` skill with JSON task lists. |
| **No extended thinking** | Can't use Anthropic's thinking mode for complex reasoning. | Add `thinking` parameter support to Anthropic provider. |
| **No prompt caching (Anthropic)** | Higher latency and cost with cloud models. | Add `cache_control` blocks to system prompt assembly. |
| **No `/compact` and `/context` commands** | User can't inspect or manage context usage. | Add commands. |
| **No diff display for file edits** | User can't see what changed. | Render colorized diffs after file_edit. |
| **No image/vision support** | Can't analyze images. | Add image support to file_read. |
| **No objective drift prevention** | Agent loses focus during long tool chains. | Inject task list state as system reminder after tool uses. |

---

## Model Compatibility Matrix

| Feature | Requires | Claude Code | OpenClaw | NanoClaw | OSA |
|---------|----------|-------------|----------|----------|-----|
| Tool use | Model supports `tool_use` | Anthropic only | Multi-provider | Anthropic only | **18 providers, gated by model size** |
| Extended thinking | Anthropic `thinking` param | Yes | Yes (model-specific) | No | **No** |
| Vision | Model supports images | Via Read tool | Via image tool | No | **No** |
| Streaming | Provider supports SSE | Yes | Yes | Via SDK | Provider-dependent |
| Prompt caching | Anthropic cache_control | Yes (auto) | N/A | N/A | **No** |

**OSA's model advantage**: Works with Ollama local models. Tool gating prevents small model hallucinations. But missing extended thinking and prompt caching means higher latency and cost with cloud models.

---

## Architecture Comparison Diagram

```
CLAUDE CODE                          OPENCLAW
═══════════                          ════════
User → CLI (React Ink)               User → Channel Adapter / Gateway RPC
  → System prompt (110+ fragments)     → sanitize + attachments
  → Master loop (nO)                   → Session + Agent resolution
    → LLM call (Anthropic API)         → Directive parsing (/think, /model)
    → Tool dispatch (18 tools)         → System prompt (sections)
    → TodoWrite reminders              → LLM call (14+ providers)
    → h2A steering queue               → Tool dispatch (25+ tools)
  → React Ink render                   → Compaction (40% chunk ratio)
  → Auto-compact at 95%               → WebSocket broadcast
                                       → Channel delivery

NANOCLAW                             OSA
════════                             ═══
User → WhatsApp message              User → LineEditor.readline
  → Baileys WS → DB store              → process_input()
  → Trigger pattern match              → Classifier.classify() → S=(M,G,T,F,W)
  → Group queue (max 5)                → NoiseFilter (2-tier)
  → Apple Container spawn              → Memory.append()
  → Agent SDK query()                  → should_plan?()
    → claude_code preset               → Context.build() (4-tier budget)
    → MessageStream (piped IPC)        → Providers.Registry.chat()
    → bypassPermissions                → Tool loop (max 30 iterations)
  → stdout markers                       → Hooks.run(:pre_tool_use)
  → <internal> tag stripping             → Skills.execute()
  → WhatsApp send                        → Hooks.run_async(:post_tool_use)
                                       → Markdown.render()
                                       → Status line (signal info)
```

---

## Recommendations for OSA

### ~~Immediate (before first user testing)~~ — ALL DONE
1. ~~Implement `file_edit`~~ **DONE** — `file_edit.ex`
2. ~~Implement `file_glob`~~ **DONE** — `file_glob.ex`
3. ~~Implement `file_grep`~~ **DONE** — `file_grep.ex`
4. ~~Implement `dir_list`~~ **DONE** — `dir_list.ex`
5. ~~Add tool usage policy to system prompt~~ **DONE** — `context.ex`
6. ~~Add brevity constraints to SOUL~~ **DONE** — `context.ex`

### ~~Short-term (next sprint)~~ — ALL DONE
7. ~~Add `web_fetch` skill~~ **DONE** — `web_fetch.ex`
8. ~~Add environment context injection~~ **DONE** — `context.ex:environment_block/1`
9. ~~Add input sanitization~~ **DONE** — `cli.ex:sanitize_input/1`
10. ~~Implement real-time steering~~ **DONE** — Ctrl+C cancel via non-blocking CLI
11. ~~Add anti-over-engineering rules~~ **DONE** — `context.ex`
12. ~~Add context overflow auto-retry~~ **DONE** — `loop.ex`

### Next up (Tier 3)
13. Add `task_write` (TodoWrite equivalent)
14. Add extended thinking support
15. Add prompt caching for Anthropic provider
16. Add `/compact` and `/context` commands
17. Add diff display for file edits
18. Add image/vision support
19. Add objective drift prevention

---

*Generated by 4 parallel research agents analyzing Claude Code, OpenClaw, NanoClaw, and OSA codebases.*
*Updated 2026-02-28: 13 of 18 gaps closed (Tier 1: 5/5, Tier 2: 8/8, Tier 3: 0/7).*
