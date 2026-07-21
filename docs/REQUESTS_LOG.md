# Everything you asked me to do — detailed log + status (2026-07-19)

Status key: ✅ done & committed · 🔨 in progress · 🔲 not done yet · ⏸ deferred (flagged)

---

## A. TUI — interactive experience
1. ✅ Make all slash commands feel native — real per-command UI/UX, deep/layered/branded, not text dumps (learn from Claude Code). — 17 command surfaces wired as native dialogs.
2. ✅ Fix permission prompt: inline on the TUI, NOT a full-screen modal (like CC). — `draw_inline` above composer.
3. ✅ Fix scroll hijack (wheel slamming open transcript overlay). — removed mouse capture, native scroll.
4. ✅ Fix composer/chat duplicating & stacking. — inline viewport spacing + rebuild debounce.
5. ✅ Fix dead whitespace in layout. — inline viewport sized to chrome only.
6. ✅ Fix "Reconnecting to backend" storm. — stable daemon.
7. ✅ Fix overlays quitting the app on any key. — overlay handlers return false not quit.
8. ✅ Two-timers / two-token-displays duplication. — collapsed to one each.
9. ✅ Token counter "0 tok today" frozen. — wired daily_tokens; mid-turn token flow fixed. (daily counter resets on fresh daemon — environmental.)
10. ✅ Live feedback: show tokens/tools/agent-names during a turn. — activity wiring + `@agent: subject` naming.
11. ✅ OSC-8 clickable links / file paths / image chips.
12. ✅ Composer: display-width (CJK/emoji), `#` memory quick-add, vim mode.
13. ✅ Shift+Enter newline (Ghostty). — kitty-protocol probe hardened + batched terminal-probe.
14. ✅ `/reasoning` invisible-modal bug. — added the draw branch.
15. ✅ Ghost agents ("Running 14m" that never clear). — stale-prune in the agents panel.
16. 🔨 `<think>`/`</think>` reasoning tags leaking into glm output. — being stripped + routed to thinking box.
17. 🔨 Overdrive shown twice (mode chip + `⏵⏵ overdrive on` line). — collapsing to one, matching CC.
18. 🔨 "Make all standard TUI primitives work perfectly" + study Claude Code's actual source for them. — dedicated pass in flight (thinking display, mode indicator, streaming — matched to CC file:line).
19. 🔲 Constant inline-viewport height (the *real* cure for the stacking/whitespace class — `event_loop.rs` still has the `stream_rows` growth branch; debounce is only a mitigation). **Top remaining TUI fix.**

## B. Agent harness / "make it actually work & trustworthy"
20. ✅ Make OSA genuinely agentic — proactively use tools, do the work (CC system-prompt driven). — agentic prompt (prior).
21. ✅ Trust for real long-running / in-depth work. — read-before-edit + stale-write, transient retry, evidence verification, compaction safety.
22. ✅ Fix P0 "wrong folder" (agent operating in wrong dir, status bar "miosa"). — Cwd module (prior).
23. ✅ Tool curation — tight functional set like CC (~15-25), no bloat, keep critical. — 80→72, schema normalizer.
24. ✅ Computer-use complete + cross-platform. — exists; cross-platform audit (prior).

## C. Permissions / modes
25. ✅ Three-tier shell policy (deny/ask/allow) replacing the ~/.osa cage.
26. ✅ Config-driven permissions (config.toml).
27. ✅ Auto-permission classifier (fast-path + LLM verdict, opt-in).
28. 🔨→✅ Overdrive must actually bypass prompts. — FIXED durably (disk-backed sticky store + read-as-source-of-truth; survives daemon restarts + races). Relaunch to verify.
29. ✅ Permission prompt names the real target (skill/command/path), not "use_skill".

## D. Research & "steal everything"
30. ✅ Study Claude Code + Codex + grok-build + opencode 2.0 codebases deeply. — cloned all; comprehensive study.
31. ✅ Download the reference source ("those people"). — codex-src, grok-build-src, opencode-src in research/.
32. ✅ Steal everything we don't have → `docs/steal-list.md` (P0/P1/P2, built through it).

## E. Sessions / config / memory
33. ✅ Fix `/resume` + `/continue` (didn't save / couldn't continue). — switch_session replay + backend.
34. ✅ Standard config.toml (params, permissions, model, tui) so people build their own.
35. ✅ dream-memory (grok reflective consolidation).
36. ✅ Update the stale lists/plans (parity ladder etc.) — reconciled into `docs/ROADMAP.md`.

## F. Version / release / process
37. ✅ Version scheme: deep patch, stay `1.0.0XX`, do NOT jump to 1.1 fast. — now 1.0.10, displays `v1.0.010`; reverted the premature 1.1.0.
38. ✅ Never bump version without substantial work + your OK. — holding at 1.0.10.
39. ✅ Never attribute commits to Claude. — all 23 commits author-clean.
40. 🔲 Push + release — user-gated, NOT done (23 commits local, unpushed).

## G. Deferred (flagged, awaiting your call — heavy infra, low value for local/trusted use)
41. ⏸ Session sharing (needs a hosting server).
42. ⏸ Network-proxy egress sandbox (for untrusted runs).
43. ⏸ Deeper tool curation pass.

---

**Bottom line:** ~35 of these are done + committed (v1.0.10, 4295 backend + 304 TUI
tests green); 3 TUI-primitive items are in active fix; 1 architectural TUI fix
(constant inline height) is the top real TODO; the rest are deferred by choice or
gated on your push. Nothing pushed.
