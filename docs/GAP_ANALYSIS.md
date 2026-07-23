# OSA Competitive Gap Analysis — CC · Codex · OpenCode · Grok-build (2026-07-21)

Synthesized from four parallel read-only source audits of the reference clones in
`~/projects/research/` vs OSA's current state (post-fleet, v1.0.28). Skips everything
`docs/steal-list.md` marks SHIPPED. Ranked by cross-harness signal × impact.

---

## TIER 1 — convergent, high-impact (the real gaps; multiple harnesses agree)

**G1. LSP-in-the-loop — post-edit diagnostics + code intelligence.** *(ALL FOUR)*
> ✅ **SHIPPED v1.0.31** (the fast core): `Verify.PostEdit` runs a single-file
> syntax/parse check after every edit/write and injects errors back into the tool
> result the same turn (Elixir in-process via `Code.string_to_quoted/2`; Go/Rust/JS/
> Python via their own tools). Full language-server code-intelligence (go-to-def /
> find-refs / cross-file type errors) remains a follow-up on the same seam.
OpenCode P0, Grok P0, CC P1, Codex (via apply_patch hooks). OSA has ZERO LSP
(`reminders.ex:30` "no LSP backend"; only one-shot tree-sitter `code_symbols`). The killer
piece: run the language server after every edit/write and inject the compile/type errors
back into the tool result, so the model sees the error it just made. Plus a nav tool
(go-to-def / find-refs / hover / call-hierarchy). **This is where OSA edits code "blind"
and every coding-agent competitor doesn't.** Effort L.

**G2. Auto-format on write.** *(OpenCode P0)* Run `mix format`/gofmt/prettier keyed by
extension after each mutation. OSA has none. Effort S — quickest high-value win, pairs
with G1.
> ✅ **SHIPPED v1.0.31** in the same `Verify.PostEdit` pass: Elixir formats in-process
> (respecting `.formatter.exs`), Go/Rust/JS·TS/Python via `gofmt -w` / `rustfmt` /
> `prettier --write` / `ruff format`; skipped cleanly when a binary is absent.

**G3. OS-level sandbox + sandbox×approval safety model.** *(Codex P0, Grok P1; CC notes it)*
Landlock/seccomp (Linux), Seatbelt (macOS), bwrap, WFP (Windows) — per-command confinement
with no container. Coupled with `SandboxPolicy{ReadOnly | WorkspaceWrite+writable_roots |
DangerFullAccess}` × run-confined-then-escalate. This is what lets Codex silently
auto-approve safely; OSA's permission engine only does allow/ask/deny and "allow" runs
UNCONFINED on the host (only heavyweight Docker/E2B otherwise). **The prize for making
overdrive/full-auto genuinely safe.** Effort L (Rust NIF/port — OSA already has the toolchain).

---

## TIER 2 — strong, high-value

**G4. Unified task registry + attach-to-any full-power background agent.** *(CC P0)*
CC has one polymorphic `Task` map (shells+agents+remote+workflows) with disk-streamed
output + attach-to-any. OSA has THREE disjoint surfaces — `bg_tasks`, `AgentEntry`
subagents, and the new fleet nodes — not unified; only `bg_tasks` is attachable. Design in
`docs/BACKGROUND_AGENTS_DESIGN.md`; the fleet work partly closes the "full-power spawn"
half. Effort L.

**G5. Config profiles.** *(Codex P1)* `[profiles.<name>]` bundling model+provider+
approval+sandbox+effort+tools+tui, `--profile` to select. OSA `config.toml` has `[model]`
only. Low-risk, high-leverage. Effort S–M.

**G6. `apply_patch` unified multi-op envelope.** *(Codex P1, OpenCode P2)* One tool call
does add+update+delete+**move** across many files, diff-validated, with LSP+format hooks; a
freeform Lark grammar tool. OSA has per-file `file_edit` (9-strategy fuzzy) + `multi_file_edit`
but no unified patch grammar or move. Effort M.

**G7. MCP OAuth + CLI lifecycle.** *(Codex P1, Grok #16/17)* `osa mcp add/remove/list/login`,
browser-loopback OAuth (PKCE + DCR), keyring token store, auto-refresh. OSA has an `oauth`
config placeholder but no login flow / CLI / token store. Effort M.

**G8. Hashline anchored read + self-heal; per-hunk accept/reject.** *(Grok P1 #5/#6)*
Read as `LINE:HASH→content`, edit by quoting anchors, re-anchor on drift; every change an
attributed hunk the user accepts/rejects individually. OSA has whole-snapshot revert
(`fs_checkpoint`) + edit-side drift guard, not the read-addressing scheme or per-hunk review.
Effort M–L.

---

## TIER 3 — productization / ecosystem

- **G9. Plugin system + marketplace** *(CC P1, Grok #14)* — distributable `plugin.json`
  bundles (commands/agents/skills/hooks/mcp/lspServers) with git/npm marketplaces +
  install/update. OSA has skills but no bundle format or marketplace. Effort L.
- **G10. ACP agent / IDE embedding** *(OpenCode #6, Grok #4, CC #5)* — be driven by
  VS Code/Zed/Cursor over stdio JSON-RPC (OSA is an MCP *server*, not an ACP *agent*);
  in-editor diff review, selection tracking, file@line at-mentions. Effort L.
- **G11. Implemented cloud/remote agents** *(CC P1)* — spawn+drive agents in a sandbox over
  WS with permission-bridge back to the local terminal + scheduled triggers. OSA is
  design-only (`OSA_REMOTE_DESIGN.md`); OpenComputers is the foundation. Effort L.
- **G12. Cache-preserving context editing** *(CC P1)* — clear old tool results WITHOUT
  invalidating the KV/prompt-cache prefix (native `clear_tool_uses_20250919` + time-based
  cold-cache pre-clear). OSA compaction doesn't preserve the cache prefix. Effort M.

---

## TIER 4 — polish (mostly S; quick wins)

- **Doom-loop resample** *(Grok #8)* — OSA *detects* loops but doesn't re-sample on a fresh
  budget; grok aborts mid-stream and re-rolls. Effort S.
- **StructuredOutput synthetic tool** *(CC, Grok)* — force the final answer into a
  caller-supplied JSON schema (Ajv/jsonschema-validated). Effort S.
- **Richer question tool** *(CC, OpenCode)* — 1–4 questions, per-option `description` +
  visual `preview`, `multiSelect`, header chips (OSA `ask_user` is single freeform+options).
- **More hook lifecycle events** *(CC ~30 vs OSA ~10)* — PostCompact, SubagentStart,
  PermissionDenied, FileChanged, CwdChanged, WorktreeCreate/Remove. Effort S.
- **Persistent lightweight shell session** *(Grok #9)* — cwd/env/aliases across `bash`
  calls via state-dump replay. Effort M.
- **Mermaid render** *(Grok #15)* — OSA shipped LaTeX render but not Mermaid. Effort M.
- **Cross-process auth refresh** *(Grok #17)* — flock + stagger so sibling logins are picked
  up. Effort S.
- **Anti-bypass shell analysis** *(Grok #7)* — detect shell reads/writes circumventing
  Read/Edit denies + cwd-poison tracking → escalate. Effort M. (Pairs with G3.)

---

## Where OSA already LEADS — do NOT regress (all four analysts concur)

- **Multi-agent depth** — full-power *recursive* fleet (16 concurrent / 1000 lifetime cap) +
  effort ladder (`fast→ultra`) + dynamic workflows + finalizer gate + teams/peer/mixture-of-
  agents. Grok subagents are depth-1 and can't nest; CC teams don't formalize the finalizer.
  **OSA's clear architectural lead.**
- **BEAM/actor isolation** — supervised OTP processes give crash isolation, subtree cancel,
  durable actors for free; competitors hand-roll it.
- **fast-worktree CoW** isolation (O(1) snapshot) > git-worktree checkout.
- **Vector/dream memory** — embeddings + MMR + dream/vigil consolidation + vault.
- **Provider breadth + resilience** — 6 families + fallback-chain/circuit/health/credential-
  pool; Codex dropped to 4 providers + Responses-API-only.
- **Long-task sleep inhibitor** — holds an OS keep-awake for the whole turn (grok doesn't).
- **Shipped and matching/exceeding**: tool virtualization, 9-strategy fuzzy edit, tree-sitter
  shell permission scanning, JSON-schema normalizer, PTY emulator, config.toml `[model]`.

---

## The one-line takeaway

OSA is the **best-in-class autonomous multi-agent orchestrator**, and as of **v1.0.31 it no
longer edits code blind**: the highest-leverage convergent gap — the **format + diagnostics
edit-feedback loop (G1 + G2)**, flagged by all four harnesses — now ships as `Verify.PostEdit`
(fast single-file core; full cross-file LSP code-intelligence is the remaining follow-up on the
same seam). The next targets are **OS-level sandboxing for safe full-auto (G3)** and **unifying
the task/agent registry (G4)**, which the fleet work has already started. Everything else is
profile/ecosystem/polish.
