# Gap Analysis — What Every Competitor Has That We Don't

> Updated: 2026-02-27

## From OpenClaw

| Feature | Impact | Effort | Priority | Phase |
|---------|--------|--------|----------|-------|
| Vector embeddings in memory search | HIGH | MEDIUM | **P0** | 1 |
| 50+ messaging channels | MEDIUM | HIGH | P2 | 3 |
| Voice/audio (TTS, STT, wake word) | MEDIUM | HIGH | P2 | 4 |
| Browser automation (CDP, Playwright) | HIGH | HIGH | **P1** | 2 |
| Web dashboard / Control UI | MEDIUM | HIGH | P2 | 3 |
| Skill marketplace (ClawHub) | MEDIUM | HIGH | P2 | 4 |
| Mobile nodes (iOS/Android) | LOW | VERY HIGH | P3 | 5 |
| Device pairing (QR + challenge-response) | LOW | MEDIUM | P3 | 5 |
| Rich TUI with navigation | MEDIUM | MEDIUM | P2 | 3 |
| IDE integration (ACP protocol) | HIGH | HIGH | **P1** | 2 |
| Auto-reply / DND modes | LOW | LOW | P3 | 4 |
| Presence system (online/offline/typing) | LOW | MEDIUM | P3 | 4 |
| Remote access (Tailscale + SSH) | LOW | MEDIUM | P3 | 5 |

## From Aider

| Feature | Impact | Effort | Priority | Phase |
|---------|--------|--------|----------|-------|
| SWE-Bench benchmark testing | HIGH | HIGH | **P0** | 1-2 |
| Git-native auto-commit workflow | HIGH | MEDIUM | **P0** | 1 |
| Auto-lint/auto-test cycle | HIGH | MEDIUM | **P0** | 1 |
| Voice input | LOW | MEDIUM | P3 | 4 |
| Image context | MEDIUM | MEDIUM | P2 | 2 |

## From Cursor

| Feature | Impact | Effort | Priority | Phase |
|---------|--------|--------|----------|-------|
| IDE integration (native) | HIGH | VERY HIGH | **P1** | 2 |
| Built-in browser for visual verification | MEDIUM | HIGH | P2 | 2 |
| Plan mode with collaborative refinement | MEDIUM | MEDIUM | P2 | 2 |
| Git worktree isolation per agent | HIGH | MEDIUM | **P1** | 2 |
| Background agents (cloud) | MEDIUM | HIGH | P3 | 5 |

## From Cline

| Feature | Impact | Effort | Priority | Phase |
|---------|--------|--------|----------|-------|
| Browser automation (Computer Use) | HIGH | HIGH | **P1** | 2 |
| Per-step human approval mode | MEDIUM | LOW | P2 | 2 |
| Timeline/rollback UI | MEDIUM | MEDIUM | P2 | 3 |

## From Goose

| Feature | Impact | Effort | Priority | Phase |
|---------|--------|--------|----------|-------|
| 1,700+ MCP extensions compatibility | HIGH | LOW | **P1** | 1 |
| Desktop app (GUI) | MEDIUM | HIGH | P2 | 3 |
| Recipe system (declarative workflows) | MEDIUM | MEDIUM | P2 | 2 |

## From Codex CLI

| Feature | Impact | Effort | Priority | Phase |
|---------|--------|--------|----------|-------|
| Three approval modes (read/auto/full) | MEDIUM | LOW | P2 | 2 |
| Image attachment support | MEDIUM | MEDIUM | P2 | 2 |

## From OpenHands

| Feature | Impact | Effort | Priority | Phase |
|---------|--------|--------|----------|-------|
| 15 built-in evaluation benchmarks | MEDIUM | HIGH | P2 | 3 |
| Web UI for interaction | MEDIUM | HIGH | P2 | 3 |

## From SWE-Agent

| Feature | Impact | Effort | Priority | Phase |
|---------|--------|--------|----------|-------|
| Self-evolving scaffold (agent modifies own tools) | HIGH | HIGH | **P1** | 2 |
| Agent-Computer Interface (ACI) | MEDIUM | MEDIUM | P2 | 2 |

## From Devin

| Feature | Impact | Effort | Priority | Phase |
|---------|--------|--------|----------|-------|
| Auto-generated project documentation | MEDIUM | MEDIUM | P2 | 3 |
| Code Q&A engine | MEDIUM | MEDIUM | P2 | 3 |
| Project management integration (Jira/Linear) | LOW | MEDIUM | P3 | 4 |

---

## Priority Summary

### P0 — Must Ship (Phase 1)
1. Vector embeddings in memory search (from OpenClaw)
2. Git-native auto-commit workflow (from Aider)
3. Auto-lint/auto-test cycle (from Aider)
4. MCP extension compatibility (from Goose)
5. SWE-Bench benchmark setup (from Aider/SWE-Agent)

### P1 — Should Ship (Phase 2)
1. Browser automation (from OpenClaw, Cline, Cursor)
2. IDE integration / LSP server (from Cursor, Cline)
3. Git worktree isolation per agent (from Cursor)
4. Self-evolving scaffold (from SWE-Agent)
5. Approval modes for tool execution (from Codex CLI, Cline)
6. Image context support (from Aider, Codex CLI)

### P2 — Nice to Ship (Phase 3-4)
1. Web dashboard UI
2. More messaging channels
3. Desktop app
4. Voice input/output
5. Skill marketplace
6. Evaluation benchmarks
7. Auto-generated documentation

### P3 — Future (Phase 5)
1. Mobile nodes
2. Device pairing
3. Remote access
4. Cloud agent execution
5. Project management integrations
