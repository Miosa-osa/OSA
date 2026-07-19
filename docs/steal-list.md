# OSA Steal-List — features worth taking from grok-build, opencode 2.0, Codex, Claude Code

Consolidated from a deep read of the real source (cloned into `~/projects/research/`:
`grok-build-src`, `opencode-src`, `codex-src`, `ClaudeCode-Source-March31`). Skips
things OSA already has (three-tier shell permissions + config.toml, read-before-edit,
transient retry, evidence verification, session resume+replay, live activity/token
feedback, sub-agent orchestration, MCP, dream-memory, session titling, OSC-8 links,
vim/`#` composer).

Effort: S = <1 day, M = a few days, L = 1–2 weeks.

---

## ✅ SHIPPED (local, v1.0.9 held, ~17 commits, not pushed)

P0: compaction tool-pair-safe split + active-agent reminder + degenerate-retry ·
tree-sitter-analog structured shell-command scanning + arity table · 9-strategy
fuzzy edit cascade · LLM-safe JSON-Schema normalizer.
P1: fast-worktree CoW isolation (capability detection + tiered ladder + teardown +
crash-recovery, wired into sub-agent isolation) · tool virtualization (search_tool/
use_tool) · lazy AGENTS.md injection · streaming frozen-tail markdown render (wired,
byte-identical) · two-log session persistence · image-budget eviction · skills
progressive disclosure · PTY emulator (pty_start/send/read/wait/stop) · session
resume+replay · OSC-8 links.
P2: <system-reminder> pipeline · doom-loop resample · header-aware retry classifier +
HTTP/1.1 rebuild · conditional tool-name-injected prompt template · MCP robustness
(SSE fallback / pagination / onprogress reset / process-group reaping / backoff) ·
batched startup terminal-probe · auto-permission classifier · composer (width/#/vim) ·
dream-memory · session titling · config.toml (model/tui/permissions).
TUI hardening: ghost-agent prune · Shift+Enter (Ghostty) · /reasoning modal fix · 304
TUI unit tests green.

## ⏸ DEFERRED (heavy infra, low value for OSA's local/trusted/single-operator use)
- **Session sharing** — needs a hosting server (Cloudflare Worker/Durable Object). Only
  useful for publishing a run to the web. Not core.
- **Network-proxy egress sandbox** — TLS-MITM + credential broker for UNTRUSTED/sandboxed
  runs. OSA runs as the trusted operator locally; large surface area for little gain.
- **Provider-plugin registry + models.dev** — in progress (the useful part: auto model
  metadata catalog).

---

## P0 — highest value, clear wins

1. **Compaction: tool-pair-safe split + active-agent reminder** (grok `xai-grok-compaction`). When trimming context, never orphan a tool result from its call (orphans → provider 400); and after a full-replace compaction, re-inject running sub-agents / TODOs / background-task IDs so the model doesn't lose in-flight work. Also: degenerate-summary rejection (retry if summary suspiciously short), context-overflow "input ladder" (compaction itself can overflow → rebuild smaller), prior-user-query preservation across re-compactions. → OSA `lib/optimal_system_agent/agent/loop/` compaction path. **M**, and the single biggest long-task correctness upgrade.

2. **Tree-sitter shell-command permission scanning** (opencode `tool/shell.ts` + `permission/arity.ts`). Parse each bash command's AST *before* running it, extract the real sub-commands + touched file paths, and scope the permission prompt to *those* (paths outside the project → an `external_directory` ask). Plus the copy-pasteable command **arity table** (`git`→2 tokens, `docker compose`→3…) for "always allow `<prefix> *`". Directly upgrades our new shell-permission tier from regex to AST. → OSA shell_execute. **M**.

3. **9-strategy fuzzy edit cascade + disproportionate-match guard** (opencode `tool/edit.ts`, from cline/gemini-cli). Exact → line-trimmed → block-anchor (Levenshtein ≥0.65) → whitespace/indent/escape-normalized → context-aware → multi-occurrence, with a guard refusing a match much larger than `oldString`. Big edit-success-rate win; pure string logic, ports to Elixir. → OSA `file_edit`. **M**.

4. **LLM-safe JSON-Schema normalizer** (opencode `tool/json-schema.ts`). Strips `additionalProperties:true`, collapses `anyOf`/`oneOf`, inlines `$ref`/`$defs`, forces bounds on unbounded ints. Directly fixes our known `Type.Union`/`anyOf`/`format` validator-rejection pain. → OSA tool schema layer. **S**.

## P1 — high value

5. **fast-worktree: CoW parallel-agent isolation** (grok `xai-fast-worktree`). Spin up a fresh isolated worktree per parallel agent in O(1) (btrfs/overlayfs snapshot) or a few-hundred-ms parallel reflink copy, instead of git checkout walking 100k files; O(1) teardown; tiered auto-detect + rootless delegate + crash-recovery metadata. Enables cheap massive fan-out. → OSA sub-agent/worktree infra. **L**.

6. **Hashline self-verifying edits** (grok `xai-grok-tools/.../hashline`). Read format `LINE:HASH→content`; the model edits by quoting `22:abc` anchors. The hash is a whitespace-normalized FNV fingerprint — edits validate against it (catches stale files) and on a shift the tool hands back the corrected anchor so the model self-heals without re-reading. Token-cheap addressing + structural stale-edit safety. → OSA read/edit tools. **M/L**.

7. **Two-tier tool-result pruning** (grok `xai-chat-state`): hard-clear old tool results in *stored* memory after N turns (frees bytes), soft-trim (head+tail keep) on a *request clone* only when context >50% full — with synthetic-message turn-age correction. → OSA context management. **M**.

8. **Image byte-budget eviction w/ KV-cache hysteresis** (grok `request_builder.rs`): keep request body under the proxy cap by evicting oldest inline images to an honest "image removed, don't hallucinate its contents" placeholder; evict in a batch to a low-water mark to preserve the KV-cache prefix. → OSA multimodal path. **M**.

9. **Session sharing** (opencode `share/` + Durable Object). Live public web view of a run: keyed-queue + 1s debounce + last-write-wins → WebSocket fan-out (one actor per session, replay-on-connect). → OSA (has HTTP+SSE bus already). **M**.

10. **Skills progressive disclosure** (grok `skills/` + opencode). Read only SKILL.md frontmatter for listings; load the body on demand; `paths`-glob lazy surfacing (a skill appears only when a matching file is touched). Claude-`.claude/skills`-compatible. → OSA skills. **M**.

11b. **Streaming frozen-tail markdown render** (grok `xai-grok-markdown/streaming.rs` + `checkpoint.rs`). Freeze a rendered prefix at depth-0 checkpoints (heading/paragraph/closed-code, only after a confirming blank line) and re-render *only* the streaming tail — O(N²)→~O(N), no flicker. Pairs with resumable-syntect incremental highlighting (persist syntect `ParseState`/`HighlightState` across pushes; highlight the tentative last line on a clone). Directly upgrades OSA's streaming render. Bonus in the same crate: terminal LaTeX (fractions/matrices/scripts as aligned monospace) and offline sandboxed Mermaid (SVG via vendored dagre → PNG via resvg, no Node/browser, out-of-process timeout + code-block fallback). → OSA `render/markdown.rs`. **M–L**.

11. **PTY emulator server** (grok `ptyctl`, on `alacritty_terminal`). Let the agent drive interactive TUIs (vim, REPLs, ssh/installers) by seeing the *rendered screen* + `WaitCondition::{Text,Regex,Gone,StableMs}` settle detection. → new OSA capability. **L**.

11c. **Git-snapshot-per-step revert** (opencode `session/revert.ts`). Capture a filesystem snapshot at every step boundary so the user can revert the workspace to any message/part ("undo the agent's last 3 steps") and un-revert, with a per-message diff summary. Flagship coding-agent safety feature. → OSA session/loop. **M**.

11d. **Directory-scoped lazy instruction injection** (opencode `session/instruction.ts`). Instead of front-loading every `AGENTS.md`/`CLAUDE.md`, inject the nearest ancestor's guidance *when the agent reads a file in that subtree*, deduped once per assistant message. Token savings + more relevant guidance. → OSA context assembly. **S/M**.

11e. **Derive-loop-state-from-persisted-messages** (opencode `session/prompt.ts runLoop` + part-based persistence in `processor.ts`). Recompute turn state from the persisted transcript each iteration (no hidden in-memory turn state) → interruption/resume/revert become trivial; persist reasoning/tool-input/tool-result/step-boundaries as distinct typed "parts". Architectural; **L** but high-leverage. Also here: **header-aware error-classified retry** (honor `retry-after`, never retry context-overflow) — **S**, drop-in.

11f. **Two-log session persistence** (grok `session/storage/jsonl`): an immutable append-only `updates.jsonl` (source of truth for replay/rewind, never touched by compaction) + a mutable `chat_history.jsonl` (the compaction-pruned transcript resent to the model). The split means compaction and rewind can never corrupt each other. → OSA session persistence. **M**.

11g. **Tool virtualization: `search_tool` + `use_tool`** (grok): don't inject all MCP tools into the base prompt — expose a BM25 search over tool descriptions + a dispatch tool, so the model discovers then invokes. Massive context savings with large MCP toolsets. → OSA MCP/tool layer. **M**.

11h. **9-section structured compaction prompt + `<user_queries>` preservation** (grok `code_compaction` + opencode): the summary template (Primary Intent / Key Concepts / Files&Code / Errors&Fixes / All User Messages verbatim / Pending Tasks / Current Work / Next Step-with-verbatim-quote), carrying the prior summary forward as authoritative to prevent drift across chained compactions, and splitting original user queries out so they never snowball or get lost. Pairs with P0 #1. **S** (mostly prompt work).

## P2 — worth it, lower urgency

18. **Cross-cutting `<system-reminder>` pipeline** (grok `src/reminders/`): after every tool call, append task-completion (surface finished background jobs so the model needn't poll), skill-discovery (SKILL.md near touched paths), and LSP-diagnostics reminders. Clean, reusable steering. **S/M**.
19. **Auto permission mode** (grok `permission/auto_mode.rs`): an LLM transcript-classifier verdict (Allow/Block) for whether a tool call is safe, with a tree-sitter bash fast-path so obvious reads skip the LLM. Layers on top of the P0 tree-sitter shell scanner. **M**.
20. **Doom-loop *resample* recovery** (grok): OSA already *detects* repeated identical tool calls — grok also *resamples* (discard + retry, bounded) as the remedy, since the fix is a re-roll not a wait. **S**.
21. **Retry classifier with HTTP/1.1 client-rebuild** (grok `sampler/retry.rs`): first 5xx rebuilds the HTTP client on HTTP/1.1 to escape a poisoned HTTP/2 pool; 413 → strip images; context-overflow = fatal even dressed as 500; honor `Retry-After`. **S**.
22. **Conditional, tool-name-injected system-prompt template** (grok `prompt/template.rs`): `${% if tools.by_kind.plan %}…${% endif %}` so sections render only for available tools, and tool NAMES are injected from placeholders so prompt text always matches the live toolset (survives renames/namespacing). → OSA `agent/context.ex`. **M**.
23. **Batched startup terminal-probe** (Codex `terminal_probe.rs`): fire CPR + OSC10/11 + kitty-flags + DA1 in one burst with a caller deadline (dup tty + O_NONBLOCK + poll) — more robust than sequential DSR queries (relevant to OSA's inline-viewport DSR flakiness). **S**.

## P2 (original) — worth it, lower urgency

12. **MCP robustness details** (opencode `mcp/` + grok `xai-grok-mcp`): StreamableHTTP→SSE fallback, paginated + schema-tolerant tool listing, `onprogress` timeout-reset, descendant-process reaping (`setsid`+`killpg`), OAuth two-layer dedup (fs-lock + watch-channel generation counter) + DCR/PKCE, SSE-reconnect exponential backoff. **M**.
13. **Codex network-proxy** — loopback HTTP+SOCKS egress gate with domain allow/deny, SSRF/private-IP blocking, optional TLS MITM, and a **credential broker** (child sees a shape-matching dummy token; real secret injected on the wire). For sandboxed/untrusted runs. **L**.
14. **Provider registry as lazy plugins + models.dev catalog** (opencode). 33 providers as dynamic-import plugins; external self-refreshing model-metadata catalog (context windows/pricing/limits) instead of hand-maintaining them. **M**.
15. **Leased-probe circuit breaker** (grok `xai-circuit-breaker`), **cross-process auth-refresh middleware** (grok `xai-grok-auth`: disk re-read picks up a token refreshed by a sibling `login`), **rollback-safe self-update** (dual-symlink atomic swap, parallel byte-range download, server-driven min-version floor). **S–M each**.
16. **Output truncation-to-file at the tool-wrapper boundary** (opencode `tool/truncate.ts`) with capability-aware "delegate to a subagent to read this" hint. **S**.
17. **Background-subagent synthetic-message injection** (opencode `task.ts`): background sub-agent returns by injecting a `<task_result>` synthetic turn into the parent — clean for OSA's actor model. **S**.

---

_Caveat: don't copy Codex/grok self-update's `--version`-only artifact verification (no checksum/signature) for hostile-network contexts._
