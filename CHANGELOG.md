# Changelog

All notable changes to OSA are documented here. This file tracks
release-level changes; the day-to-day build ledger lives in
[`docs/BACKLOG.md`](docs/BACKLOG.md).

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

---

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
