# OSA Agentic Build — parallel fan-out plan (lane-partitioned)

Goal: build the entire agentic-workflow backlog (from `scratchpad/agentic_*.md` +
the TUI bug-hunt + layer-audit) at maximum safe parallelism.

**The real constraint is file contention, not agent count.** OSA's backend has a few
HOT files that many units touch — `react_loop.ex`, `orchestrator.ex`, `context.ex`,
`compactor.ex`, `loop.ex`. Two agents editing the same file in parallel = merge chaos.
So work is partitioned into **lanes** = disjoint file-ownership groups. Lanes run in
parallel; units within a lane that share a hot file run sequentially. The lead
(me) owns the hottest cross-cutting file, `react_loop.ex`, and does all its wiring
sequentially after each wave lands, then gates + commits the batch. This is what lets
the fan-out scale to 10–40 concurrent builders without stomping.

Gate for EVERY unit: `OSA_HTTP_PORT=0 mix compile` clean + focused tests + relevant
existing tests. TUI units also `cargo build --release` + `cargo test`. No version
bump, no daemon restart, no commit inside agents — the lead gates + commits per wave.
No Claude attribution, no push (user-gated).

Optional adversarial pairing: each builder can be shadowed by a read-only verifier
agent that tries to refute the implementation — doubles the agent count and catches
plausible-but-wrong work before it merges. Use for the L-effort / high-risk lanes.

---

## WAVE 1 — IN FLIGHT (4 agents)
| Lane | Owned files | Unit |
|------|-------------|------|
| plan | context.ex(plan block), plan_store.ex, plan_mode.ex, loop.ex(plan handlers), new plan tools | investigative plan mode + durable plan file + Enter/ExitPlanMode tools |
| recover | fallback_chain.ex, llm_client.ex, retry_classifier.ex, doom_loop.ex(+reasoning_only.ex), tool_executor.ex/reminders.ex | header-aware retry + reasoning-only doomloop + first-failure self-correction |
| compact-quality | compactor.ex, compaction_safety.ex(call) | verbatim `<user_query>` + token-budgeted tail + D&C chunked summary |
| tui-bugs | TUI: sse.rs, main.rs, update.rs, handle_backend.rs, handle_actions.rs, input/mod.rs, event_loop.rs | 10 P0/P1 bug-hunt findings |
| **lead** | **react_loop.ex** | forced max-steps wrap-up + post-compaction auto-continue + token-budget continue (after wave lands) |

## WAVE 2a — LAUNCH NOW (disjoint from Wave 1's files)
| Lane | Owned files | Unit | Effort |
|------|-------------|------|--------|
| rag | memory/search.ex(new), mmr.ex(new), query_expansion.ex(new), scoring.ex, store.ex — expose recall API; lead wires context.ex later | hybrid RAG: vector KNN + MMR + query-expansion | L |
| goal-verify | orchestrator.ex, new agent/loop/goal_verifier.ex; describe (not apply) react_loop hook | goal-level verifier subagent (majority-refute over diff) | L |
| rewind | fs_checkpoint/server.ex, loop/checkpoint.ex, api.ex(rewind route), new rewind module | unified /rewind: file restore + msg truncate + unrevert + diff | M |

## WAVE 2b — after 2a frees orchestrator (sequential on orchestrator.ex)
- multi-turn goal orchestration + stall auto-pause (goal_tracker.ex; builds on goal-verify) — L
- peer-resume sibling handoff (delegate/handler.ex + orchestrator fork) — M
- completed-child worktree durable snapshot (fast_worktree.ex + orchestrator cleanup) — S
- blocking join-barrier tool (tools/builtins/task_wait + orchestrator wait-accounting) — M
- transitive/recursive cascading cancel (loop.ex — after plan lane frees it) — M

## WAVE 2c — compactor follow-ons (sequential on compactor.ex, after Wave 1 compact-quality)
- token-protected prune tier — M
- media-strip + replay on media overflow (compactor + react_loop replay) — M
- summary structural validation (if not fully covered by Wave 1 D&C) — S

## WAVE 3 — TUI (after tui-bugs lane frees the TUI files)
- constant inline-viewport height — delete `stream_rows` growth branch in event_loop.rs
  (the "real cure" for the stacking/whitespace class) + remove PlanReview from is_overlay
- mouse capture + click-to-caret + wheel passthrough
- dead-wiring cleanup (Sidebar/Doctor/Mcp), remaining bug-hunt P2s, overlays/keyboard cluster

## Lead-held cross-cutting (react_loop.ex — sequential, between waves)
- forced max-steps wrap-up turn · post-compaction auto-continue · token-budget continue
- message-derived loop state + message-embedded task queue (L, architectural — last)
- media-strip replay path · reasoning-only doomloop react_loop hook if flagged

---

## Concurrency math
Genuinely disjoint lanes at any moment ≈ 8–12 backend + TUI. Worktree isolation
(`isolation:'worktree'` on the Agent tool) lets even hot-file lanes build in parallel
copies when needed — at the cost of a manual merge-review per agent, so it's used only
where direct disjoint-partitioning can't reach. Workflow's own concurrency cap is
min(16, cores−2); excess queued. So the practical ceiling for a single clean wave is
~10–16 concurrent builders + their verifiers; 30–40 is reached by chaining waves, not
one blast. Every wave: lead gates + commits + then fires the next.
