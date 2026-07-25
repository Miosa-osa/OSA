# Changelog

All notable changes to OSA are documented here. This file tracks
release-level changes; the day-to-day build ledger lives in
[`docs/BACKLOG.md`](docs/BACKLOG.md).

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

---

## [1.0.40] — displays as `v1.0.040`

### Fixed — TUI audit: 14 rendering defects across 3 root causes

A full audit of the TUI (live-region geometry, text rendering, turn lifecycle)
found that most visible glitches traced to three structural gaps rather than
independent bugs. All three are now closed.

**Root cause 1 — the live region's height was computed twice, and some components
drew without being in the budget at all.**

- **Typing a `/` command no longer wipes the screen.** The completions popup
  recomputes its height on every keystroke, and that was aliased onto the "terminal
  resized" flag — so each character took the destructive full-screen clear path and
  re-anchored the viewport at row 0. Popup changes now commit promptly but clear
  *surgically*; only a real terminal resize takes the full wipe.
- **No more dead rows under the spinner.** The activity slot reserved a flat 6 rows
  and drew its accent rail across all of them, trailing bare rail glyphs down the
  empty rows. The slot is now sized exactly to the current verbosity and the content
  is bottom-anchored, so the spinner sits tight above the composer.
- **Verbose mode no longer silently drops tool rows** — it needs 9 rows and the flat
  cap gave it 6, clipping the three oldest feed entries.
- **Screen-reader mode no longer leaves 11 blank rows** above the composer (sizing
  reserved the expanded thinking box while drawing the 1-row plain-text line).
- The agents roster's reserved and drawn heights agree again, and it is
  bottom-anchored like the activity feed.

**Root cause 2 — no column-width primitive, so eight near-duplicate "fit to width"
helpers existed at three different correctness levels.**

- Added `util::fit_cols` / `util::cols` as the canonical column-aware fitters and
  routed session titles, file-picker names, toasts, and the agents roster through
  them. Previously these compared **byte** length (or char count) against a **column**
  budget, so any CJK/emoji text was cut to roughly a third of its space — and because
  toasts are right-aligned, they lost their *beginning*.
- **Every wrapped bullet in every reply was mis-indented.** The list renderer measured
  its `"• "` prefix in bytes (4) rather than columns (2), so continuation lines sat two
  columns right of their own first line and wrapped early.
- The welcome banner centred by byte length, so any non-ASCII name or path made the
  first screen lopsided.

**Root cause 3 — width-blind heights + unwrapped prose.**

- **Permission prompts no longer clip the backend's warning and reason.** These
  reserved exactly one row each and rendered unwrapped, so safety text the user is
  being asked to approve could be cut off mid-sentence. Both now wrap, and the
  reserved height is computed from the same wrap.
- Plan/checklist items no longer clip mid-word or show raw `**bold**`: subjects are
  markdown-stripped and fitted to the real render width (threaded through instead of
  guessed), so each occupies exactly the one row the cell reserves. The same three
  fixes were applied to the separate task panel.
- Markdown tables keep their right border — the width cap subtracted the borders but
  forgot the `" │ "` separators, leaving the capped table too wide to fit.

**Turn lifecycle**

- The plan snapshot is now flushed synchronously at turn end and the live checklist
  retired, fixing both the recap/plan ordering race (a ~400ms debounce could land the
  plan *after* "Worked for Ns") and a stale plan redrawing over the **next** turn's
  reply.

**Tests**

- Added the live-region slot invariant (reserved rows ≥ drawn rows, and exactly equal
  when saturated) across every verbosity and screen-reader mode. No test previously
  compared reservation against layout — which is why these regressions shipped green.

## [1.0.39] — displays as `v1.0.039`

### Added — action authority + OpenComputers remote client

- **Unified action authority (#93 + #94).** Governed tool execution now routes through one
  fail-closed control-plane authority: HTTP, MCP, scheduled/away-mode jobs, interactive
  agents, deferred tools, and sub-agents share exact capability identifiers and
  server-published versioned fingerprints, with one-time approvals bound to the exact
  parameters and execution surface. Purely local tools stay offline and ungoverned; OSA's
  local non-bypassable machine safety remains a separate earlier layer. Ships the canonical
  MIOSA capability contract (206 capabilities, SHA-pinned) plus the routing that enforces it.
  *(This is an evolving cross-repository feature; behaviour is fail-closed and gated.)*
- **OpenComputers account remote client (#92).** New `osa opencomputers remote hosts` /
  `remote exec --host <id> -- <command>` / `remote agent --host <id> --prompt <prompt>` — a
  versioned, TLS-only remote-client envelope that keeps the MIOSA account credential in memory
  (resolved from `miosa login` or `MIOSA_PLATFORM_API_KEY`, never persisted in host config).
  v1 supports one-shot exec/agent operations; no interactive PTY routing yet.

## [1.0.38] — displays as `v1.0.038`

### Fixed — TUI live-region stability (systematic pass, not one-off)

Following a full audit of every inline-viewport height contributor (cross-checked against
ratatui's `insert_before` source), three more instances of the same bug class were fixed so
the composer can no longer stack or the screen wipe during a turn:

- **Agents roster is now a fixed slot.** Like the activity feed and streaming preview, the
  multi-agent roster grew one row per spawned fleet node mid-turn, rebuilding the viewport and
  stacking chrome. It now reserves a constant slot whenever shown.
- **Thinking box is now a fixed slot when expanded.** Expanded reasoning grew the box
  line-by-line as it streamed (1→12 rows), rebuilding the viewport on every line. It now
  reserves its constant max; the header + last ≤10 lines render into it.
- **No more transcript wipe after a message flush.** `last_inline_top` (the anchor for the
  surgical height-change clear) was only refreshed at rebuild points, but `insert_before`
  (flushing finalized messages to scrollback) moves the viewport top down every time. The
  stale anchor made the next clear wipe the just-flushed transcript. It's now refreshed after
  every flush.

Known remaining edge (tracked): on terminals that *reliably* drop the cursor-position query,
a rebuild degrades to full-screen and finalized messages can be silently dropped rather than
shown — a separate fix.

## [1.0.37] — displays as `v1.0.037`

### Fixed — composer no longer stacks down the screen during an agent turn

- **The real fix for the mid-turn staircase.** As tools ran during a turn, the live
  activity/tool feed grew one row per tool (`pwd`, then `ls`, then `date`…), and that growth
  grew the inline viewport height **mid-turn** — each growth rebuilt the viewport (a DSR cursor
  re-anchor), stacking a fresh composer + status bar down the whole screen. The streaming
  preview was already given a fixed-height slot to prevent exactly this; the activity feed was
  not. It now reserves a **constant fixed slot** for the whole turn (the feed draws top-down
  into it), so the viewport height stays stable, no per-tool rebuild happens, and nothing
  stacks. **Validated live** against a real agent turn executing shell tools: single composer,
  no stacking, no crash.

## [1.0.36] — displays as `v1.0.036`

### Fixed — resize wipe was firing on every height change (regression)

- **The screen no longer wipes/stacks on notices, typing, or scrolling.** The DSR-free
  full-screen `ClearType::All` from the resize fix lived in the shared commit block, which
  fires on **any** inline-height change — not just terminal resizes. So a transient notice
  ("New session", "Coordinator mode off"), the composer growing, or scrolling all wiped the
  whole screen and re-anchored, stacking composers and clearing the transcript on every
  keystroke. Now the full-screen wipe runs **only on an actual terminal resize** (where reflow
  makes surgical clearing impossible); a pure height change clears surgically from the tracked
  region top, preserving the transcript above.

## [1.0.35] — displays as `v1.0.035`

### Fixed — update check hit a dead endpoint

- **The update checker no longer fails against a dead service.** `OpenComputers.Updater`
  (the background auto-check and `osa update check/apply`) queried
  `https://api.miosa.ai/api/v1/opencomputers/osa/latest`, which returns **503
  "version_not_configured"** — no release is published there — so every check failed and the
  background loop logged repeated failures. It now checks **GitHub Releases**
  (`/repos/Miosa-osa/OSA/releases/latest`), the same source the installer and the `osa update`
  launcher already use.
- The checker is now **check-only**: it detects a newer published release and reports
  `{:available, version}` (the actual `osa update` launcher applies it via the GitHub release
  tarball — this Elixir path only ever staged a single binary, which never matched how OSA
  ships). Also fixes version comparison against the zero-padded display tag (`v1.0.034`), which
  `Version.parse/1` had been rejecting as an invalid leading zero.

## [1.0.34] — displays as `v1.0.034`

### Fixed — Ollama Cloud onboarding (client-blocking)

- **Selecting "Ollama Cloud" with an API key now verifies against `https://ollama.com`, not
  a local daemon.** The onboarding health-check was **local-first**: it probed for a local
  Ollama daemon and only fell back to the cloud endpoint if none was found. So an explicit
  cloud selection could get hijacked to `http://localhost:11434` — which does not serve a
  `:cloud` model like `glm-5.2:cloud` — and verification died with
  `error sending request for url (http://localhost:11434…)`.

  Corrected priority: **cloud selection ⇒ cloud URL, always.** When a key is supplied, verify
  against `ollama.com` with the Bearer key. Only a **keyless** cloud selection falls back to a
  reachable local device-identity daemon. Every other provider was already correct (Anthropic →
  `api.anthropic.com`, OpenAI → `api.openai.com`, OpenRouter → `openrouter.ai`, Ollama Local →
  `localhost:11434`).

## [1.0.33] — displays as `v1.0.033`

### Fixed — TUI resize, for real this time (duplication AND crash)

- **Resizing the terminal no longer duplicates the composer or crashes.** On terminals
  that don't answer the cursor-position query (DSR) quickly during a resize — tmux, some
  SSH sessions, and others — the inline live region could not be located after the terminal
  reflowed, so earlier surgical-clear attempts either **stranded a staircase of old
  `N% context used` + divider rows**, or (when left to ratatui's auto-resize) crashed with
  `Error: The cursor position could not be read within a normal duration`.

  Since surgical clearing is impossible without a working DSR, the resize path now does a
  **DSR-free full-screen wipe** (`ClearType::All`) before rebuilding the region fresh —
  exactly one copy of the chrome can ever exist and the reflow position never matters.
  Validated against a DSR-dropping pane across widen / narrow / rapid-resize bursts: no
  duplicate, no crash.

  Trade-off: the on-screen transcript is cleared on resize (it repaints from the live region
  down). The finalized conversation still lives in the terminal's scrollback history and the
  in-app transcript viewer — only the on-screen copy is redrawn.

## [1.0.32] — displays as `v1.0.032`

### Fixed

- **TUI resize duplication — corrected anchor.** v1.0.31's fix anchored the inline-region
  clear to the *bottom* of the screen, which is only right when the region is pinned to the
  bottom (a screen full of transcript). In a fresh / near-empty session the live region sits
  high on the screen with blank space below it, so the bottom-anchored clear wiped empty rows
  and left the real composer/status untouched — the duplicate persisted. The clear now homes
  to the region's **actual tracked top** (`last_inline_top`, captured at startup and every
  rebuild), clamped into the resized screen, so it erases the on-screen chrome whether it sits
  high (empty session) or low (full screen); the rebuild re-anchors the fresh region at the
  same row, leaving exactly one copy.

## [1.0.31] — displays as `v1.0.031`

### Added — post-edit format + diagnostics loop (stop editing blind)

- **OSA no longer edits code blind.** After every `file_edit` / `multi_file_edit` /
  `file_write` / `file_create`, the touched file is run through a fast, single-file
  **format + diagnostics** pass and any syntax/parse error is injected back into the tool
  result the **same turn** — so the model sees the mistake it just made instead of
  discovering it 20 tool-calls later. This was the top convergent gap versus Claude Code,
  Codex, OpenCode and Grok (`docs/GAP_ANALYSIS.md` G1 + G2).
  - **Auto-format on write** — Elixir formats **in-process** via `Code.format_string!/2`
    (respecting `.formatter.exs` opts, no `mix` startup cost); Go/Rust/JS·TS/Python use
    their single-file formatter (`gofmt -w`, `rustfmt`, `prettier --write`, `ruff format`).
  - **Fast diagnostics** — Elixir syntax via `Code.string_to_quoted/2` (instant, in-process);
    Go via `gofmt -e`, Rust via `rustfmt`, JS via `node --check`, Python via `ruff check` /
    `py_compile`; TS/TSX parse errors surface through `prettier`.
  - Dependency-light and **degrades to a no-op** when a tool binary is absent; each command
    is time-boxed; a file that fails to parse is left byte-for-byte untouched and its error
    reported. Wired via the pluggable `:diagnostics_provider` seam; disable with
    `config :optimal_system_agent, post_edit_verify: [enabled: false]`.

### Fixed

- **TUI — resizing no longer duplicates the composer/status bar.** The inline-region rebuild
  cleared old chrome anchored to a `crossterm::cursor::position()` **DSR query**, which tmux
  and some emulators drop or answer with a stale row during a resize burst (a pane drag fires
  many `Resize` events) — stranding a duplicate composer while a fresh one drew below. The
  clear now anchors to the bottom-anchored region geometry derived from
  `crossterm::terminal::size()` (an ioctl reflecting the applied resize, no escape round-trip
  to drop): deterministic for grow/width-only changes, exact for shrink.

## [1.0.30] — displays as `v1.0.030`

### Fixed / robustness

- **A port conflict no longer crashes the whole app.** When `OSA_HTTP_PORT` (default 9089)
  was already in use, OSA hard-crashed on boot — Bandit failed to bind, the supervisor
  restarted it 10×/60s, and the entire OTP tree died with a cryptic dump. Now a boot
  **preflight** halts cleanly with an actionable message that distinguishes *another OSA
  instance already running* ("connect to it, or set `OSA_HTTP_PORT`") from *a foreign
  process holding the port* ("free it — `ss -ltnp | grep 9089` — or set `OSA_HTTP_PORT`"). A
  single shared `Net.Port` helper backs every surface below.
- **`osa doctor`** now reports three distinct states — OSA responding, OSA not running, and
  **port taken by a non-OSA process** (the case it previously misdiagnosed as "API not
  responding"). It also reads `OLLAMA_URL` (was `OLLAMA_HOST`, misaligned with the app).
- **Onboarding** warns if the HTTP port is already taken *before* you finish setup, instead
  of completing "successfully" and then crashing on first launch.
- **TUI** — the "backend unreachable" message now names the port and points at `osa doctor`
  instead of a vague dead-end.

## [1.0.29] — displays as `v1.0.029`

### Fixed

- **Context meter read far too high on Ollama Cloud models.** For a `:cloud` model running
  through the `:ollama` provider (e.g. `glm-5.2:cloud`), the usage denominator collapsed to
  the local Ollama KV-cache ceiling (`ollama_num_ctx`, ~32k → ~12.7k after the reserve)
  instead of the model's real context window (1,000,000) — so a normal ~15k-token turn read
  **over 100%** and the bar filled almost instantly. `effective_context_window/2` now skips
  the local KV cap for `:cloud` models, so the meter (and context budgeting + `num_ctx`
  sizing, one source of truth) use the true window. A ~50k-token session now reads ~5%
  instead of pinned-full.

## [1.0.28] — displays as `v1.0.028`

This cycle built an agent **fleet**: a Claude-Code-parity roster of full-power
sub-agents, dynamic multi-agent **workflows**, a renamed **effort ladder** that
gates them, and — the capstone — **self-orchestration** so OSA can decompose a
task into disjoint file-owned workstreams, fan out a collision-free wave in
isolated worktrees, verify it, and commit itself. See `docs/FLEETVIEW_DESIGN.md`,
`docs/FLEET_ORCHESTRATION.md`, and `docs/FLEET_EDGE_CASES.md`.

### Agent Fleet

- **FleetView roster** — a live, arrow-selectable panel under the composer: a
  green never-killable `main` root row plus one row per running node (agent-type,
  live activity, elapsed, `↓ tokens`). `←` browses, ↑/↓ select, Enter attaches a
  read-view of a node's stream, `x` stops it. Inline roster is bounded to 8 rows
  (`+K more`); the `/agents` dashboard lists all.
- **Full-power spawn** (`Fleet.spawn_fleet_node`) — each node is a complete OSA
  loop (full tools/MCP/memory/permissions) on its own session with its own
  custom-agent system prompt + tool allowlist, joined to the run tree. Not the
  restricted delegate path.
- **`fleet` tool** — the model auto-invokes it (`action: spawn | workflow`);
  spawning is automatic, `/fg` and `←` are optional viewing. Depth- and
  fleet-cap-guarded (spawn-bomb safe).
- **Dynamic workflows** (`Fleet.fan_out`) — fan out one full-power node per item
  through a 16-concurrent bounded pool with FIFO queue-drain, a 1000-node
  run-lifetime kill switch, and a live `N/16` roster counter. Per-node timeout,
  per-item error isolation, and a whole-tree budget guard that stops spawning when
  the fleet budget is exhausted. Nodes coordinate through the shared scratchpad.

### Effort

- **Ladder renamed** to `fast / medium / high / xhigh / ultra` (was
  `low/medium/high/max`), with a back-compat normalizer so persisted `:low`/`:max`
  settings keep working. Effort = how much it thinks; the current tier is shown
  live in the thinking indicator (e.g. *"thinking harder with ultra effort"*).
- **`ultra`** is the max tier and the gate for dynamic workflows. Effort drives the
  provider thinking budget across Anthropic / OpenAI / Gemini / Ollama (verified
  matrix); opus honors an explicit max budget at `ultra` instead of always adaptive.

### Self-orchestration

- **Worktree-per-node isolation** (`isolation: :worktree`) so parallel nodes edit
  their own worktrees and never collide.
- **`Fleet.Finalizer`** — merges disjoint node diffs, runs an authoritative gate,
  and commits when green (scoped `git add -- <file>`, attribution-clean, never pushes).
- **The loop is closed end-to-end** — `fan_out` waits for each node to complete before
  capturing its worktree diff (so the finalizer merges *real* changes), and the `fleet`
  tool exposes `isolation` + `finalize` (gate + commit) so the coordinator can run the
  whole recon → isolate → merge → gate → commit flow. (Unit-verified end to end; a
  live-repo integration test is the next follow-up.)
- **Fleet Orchestration playbook** (`priv/skills/fleet-orchestration`) — teaches the
  coordinator the disjoint-workstream method: recon → partition by file ownership →
  isolate → structured reports → finalize → checkpoint.

### Durability & recovery

- **Budget survives restart** — the `max_budget_usd` cap is persisted in the
  checkpoint and restored, so a crash can no longer reset it to zero.
- **Crash recovery** — stale `:running` rows are reconciled at boot; an opt-in
  resumer re-dispatches orphaned autonomous runs.

### Hardening

- Fleet edge cases across `fan_out` (timeout / error isolation / empty-huge items),
  fleet-tool argument validation, and scratchpad concurrency (cluster-serialized
  writes). Two provider thinking bugs fixed (OpenAI silently disabling reasoning on
  a bad effort value; Gemini `nil > 0` term-ordering emitting a bogus budget).
  FleetView keyboard navigation verified end-to-end. **TUI resize no longer duplicates
  content** — the inline-viewport clear now anchors to the actual cursor instead of
  ratatui's stale pre-resize geometry, which had been scrolling old chrome into
  scrollback on every resize. Intermittently-flaky tests stabilized at the root cause
  (session-scoped event capture; `async: false` where global app-env is shared). Full
  suite: 5116 tests, 0 failures.

## [1.0.10] — displays as `v1.0.010`

This cycle closed out the CC-parity backlog: 16 workstreams across the agent
loop, memory, delegation, tools, ops, and the Rust TUI. Grouped by area
below; see `docs/BACKLOG.md` for the item-by-item scoreboard and commit
references.

### Agent

- **Investigative plan mode** — `enter_plan_mode` / `exit_plan_mode` tools
  route through `Agent.Loop.enter_plan_mode/1`, gating the session to
  read-only tools until the plan is exited. The plan text is a **durable
  file** (`~/.osa/sessions/<id>.plan.md`, next to the progress ledger) rather
  than transient state, so a plan survives context resets, restarts, and the
  approve/reject/edit round-trip.
- **Goal-level verifier** (`Agent.Loop.GoalVerifier`) — an independent,
  read-only skeptic panel (N subagents, majority-refute vote) that judges
  whether the user's *goal* was met, not just whether a file compiles. Off by
  default; fail-closed to `:incomplete` on ties or missing data. Run-capped
  and stall-gated so it never spins forever.
- **Multi-turn goal orchestration** (`Agent.Loop.GoalTracker`) — a
  cross-turn, ETS-backed status machine (`:active | :paused | :completed |
  :off_track`) that survives across top-level turns. Auto-pauses on a
  cross-turn stall (two verification rounds citing the same gap) or a
  lifetime run cap, and gates the (expensive) verifier panel on a reverify
  cadence instead of every turn.
- **Reasoning-only doomloop detector** (`Agent.Loop.DoomLoop.ReasoningOnly`) —
  catches a model spinning in pure thought (zero tool calls) or repeatedly
  erroring, which the existing tool-call-keyed detectors can't see. Halts
  after a small consecutive-streak threshold and forwards to the existing
  `Resample` remedy.
- **Forced max-steps wrap-up** — hitting the iteration cap now triggers one
  final tools-disabled model turn that writes a real state summary/handoff
  instead of a canned line. Guarded so hitting the cap can never crash the
  turn.
- **Header-aware retry** — provider resilience honors a `Retry-After` header
  from the provider (capped at 60s) instead of blind exponential backoff,
  and can rebuild the HTTP/1.1 client / strip images on a header-driven
  retry decision.
- **First-failure self-correction** — the verification gate is *grounded*:
  it re-prompts only after an external check (build/test/lint) actually
  fails, following the CRITIC / "LLMs Cannot Self-Correct" research —
  ungrounded self-judgment is avoided.
- **Token-budget "work to target"** — `target_output_tokens` (state or app
  env) keeps the loop auto-continuing until a caller-specified output-token
  budget is met, capped at a small number of continues.

### Context / Memory

- **Hybrid RAG recall** — vector KNN (`Memory.Search`, cosine similarity)
  fused with MMR diversity re-ranking (`Memory.MMR`) and dependency-free
  query expansion (`Memory.QueryExpansion`, synonym table + stemming) for
  the lexical scoring path. Degrades gracefully to keyword-only scoring when
  no embedding provider is configured or a call fails.
- **Persisted vector store** — embeddings are now durably stored one row per
  memory id in a `memory_vectors` table in the same SQLite database the
  memory store uses, with an ETS warm-read cache in front. Content-hash
  invalidation re-embeds on content drift.
- **Compaction quality**:
  - Verbatim latest-user-query preservation — the most recent `user` message
    is wrapped in `<user_query>` tags and prepended to any generated
    summary, untouched by the summarizing LLM.
  - Token-budgeted, turn-aware tail selection — `preserve_recent_budget`
    (25% of the usable context window, clamped `[2_000, 8_000]`,
    operator-overridable) replaces a fixed message-count tail.
  - Prune tier — a non-LLM pass that erases old (out-of-budget) tool-result
    output outright rather than summarizing it, with a protected-tools
    allowlist and a minimum-reclaim gate before it bothers mutating anything.
  - Media-strip + overflow replay — on context-overflow retries, media
    blocks are stripped from messages before retrying, up to 3 overflow
    retries.
- **Post-compaction auto-continue** — after a compaction pass changes the
  message list, the loop can auto-continue the turn (gated by
  `ProactiveCompaction.continuation_enabled?/0`) instead of silently
  returning a truncated response.

### Delegation

- **Transitive cascading cancel** — `Loop.cancel/1` now BFS-walks the
  parent/child session tree and cancels every descendant sub-agent, plus
  batch-kills their background shell commands in one pass
  (`BackgroundManager.cancel_for_sessions/1`).
- **`task_wait` join-barrier depth ceiling** — a blocking wait on other
  agents' completion can no longer nest arbitrarily deep; `max_depth/0`
  (default 3, `:max_blocking_wait_depth`) is checked before a wait starts,
  denying requests that would exceed the ceiling instead of blocking and
  failing later.
- **Peer-resume (sibling handoff)** — a sub-agent run can be seeded from a
  sibling/peer's accumulated context (`resumed_from`) rather than starting
  fresh or forking from the parent; surfaced in run metadata for lineage.
- **Worktree durable snapshot** — `FastWorktree.snapshot_ref/2` commits any
  uncommitted worktree changes and writes a durable git ref
  (`refs/osa/subagent-snapshots/...` by default) before teardown, so a
  sub-agent's work stays inspectable/resumable without being merged or lost.

### Tools

- **Hashline drift-guard edits** (`FileEdit.DriftGuard`) — a second,
  independent content-hash guard on top of `FileState`'s `{mtime, size}`
  check, closing the blind spot where two different file states collide on
  the same size within the same wall-clock second. Only ever *stricter* than
  the existing guard; never blocks a legitimate re-read/edit cycle.
- **Output-shorten-to-file** (`Agent.Loop.ToolResultStorage`) — tool results
  over 50KB or 2,000 lines are persisted to `~/.osa/tool-results/<id>.txt`
  and replaced inline with a head/tail preview (40/20 lines) plus a file
  reference, preventing context bloat from huge shell/grep output.

### Ops

- **Rollback-safe self-update** (`osa update`, `bin/osa-update`) — dual
  symlink (`current` / `previous`) atomic swap: stage a fresh git-worktree
  checkout, build it, boot-probe its `/health` endpoint, and only then
  atomically repoint `current`. A post-swap health re-check auto-rolls-back
  to `previous` on failure. `osa update --staged`, `osa update --rollback`,
  and `--dry-run` are all supported; nothing is mutated on a dry run or a
  failed build/health gate.

### TUI

- **Composer** — structured `@`-mentions (file/dir/agent, with a per-kind
  glyph in the popup), ghost-text completion, `!`-prefixed bash submit mode,
  a huge-input pill for large pastes, and frecency-ranked mention recall.
- **Render** — LaTeX-to-Unicode conversion, richer table-cell markdown
  (nested quotes, tabs, soft breaks), bold-italic/setext heading support,
  and a raw-source toggle (`alt+r`).
- **Notifications / focus / clipboard** — terminal focus tracking (DECSET
  1004), OSC 9;4 progress reporting, a sleep inhibitor during long runs, an
  audio completion cue, kitty click-to-focus, a layered clipboard, and a
  configurable notification channel (`OSA_NOTIFY_CHANNEL`, opt-out via
  `OSA_NO_NOTIFY`).
- **Status / activity** — esc-again-to-interrupt, a watcher/background cue,
  a queued-message hint, usage-percent + low-balance indicator, an MCP
  status chip, width-gated spinner, and a subagent footer.
- **Fixed-height streaming viewport** — the inline chat viewport now holds a
  constant height while streaming instead of reflowing the terminal on every
  chunk.

### Deferred (documented, not dropped)

See `docs/BACKLOG.md` → "Deferred with rationale" for the reasoning behind
message-derived loop state (crash-resume), structured `@file`/`@agent` refs
on the wire, and the remaining crossterm-blocked mouse items.

---

## Older history

Earlier, pre-cycle entries live in [`docs/operations/changelog.md`](docs/operations/changelog.md).
