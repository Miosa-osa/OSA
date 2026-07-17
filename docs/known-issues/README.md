# Known Issues

> **OSA v1.0.002** · Last updated: 2026-03-14
> 18 open issues · 4 fixed · 3 critical · 4 high · 6 medium · 5 UX

---

## How This Section Works

Each issue has its own file organized by severity. Issues follow a consistent
template (see [TEMPLATE.md](TEMPLATE.md)) and include component mapping, root
cause analysis, reproduction steps where available, and suggested fixes.

**Severity levels:**

| Level | Meaning | Response Time |
|---|---|---|
| **CRITICAL** | Core functionality broken — agent cannot perform primary tasks | Immediate |
| **HIGH** | Important feature broken or missing — significant user impact | Next release |
| **MEDIUM** | Feature degraded or missing — workaround available | Backlog |
| **UX** | User experience issue — functional but confusing or incomplete | Backlog |

---

## Issue Index

### Critical (3)

| ID | Title | Component | Status |
|---|---|---|---|
| [BUG-004](critical/BUG-004-tools-never-execute.md) | Tools never execute — raw XML returned | Agent Loop | Partial fix |
| [BUG-009](critical/BUG-009-llm-hallucinates-tools.md) | LLM picks wrong tools / hallucinates actions | Tool Selection | Open |
| [BUG-017](critical/BUG-017-system-prompt-leak.md) | System prompt leaks on direct request | Security | Open |

### High (4)

| ID | Title | Component | Status |
|---|---|---|---|
| [BUG-005](high/BUG-005-tool-name-mismatch.md) | Tool name mismatch on iteration 2+ | Agent Loop | Open |
| [BUG-006](high/BUG-006-noise-filter-broken.md) | Noise filter not working | Noise Filter | Open |
| [BUG-011](high/BUG-011-orchestrator-404.md) | /api/v1/orchestrator/complex returns 404 | HTTP Router | Open |
| [BUG-012](high/BUG-012-swarm-status-404.md) | /api/v1/swarm/status/:id returns 404 | HTTP Router | Open |

### Medium (6)

| ID | Title | Component | Status |
|---|---|---|---|
| [BUG-007](medium/BUG-007-ollama-fallback.md) | Ollama always in fallback chain | Provider Config | Open |
| [BUG-008](medium/BUG-008-analytics-no-handler.md) | /analytics command has no handler | CLI Commands | Open |
| [BUG-010](medium/BUG-010-negative-uptime.md) | Negative uptime_seconds in /health | Health Endpoint | Open |
| [BUG-015](medium/BUG-015-swarm-silent-fallback.md) | Invalid swarm patterns silently fall back | Swarm System | Open |
| [BUG-016](medium/BUG-016-unicode-mangled.md) | Unicode mangled in DB storage | Data Storage | Open |
| [BUG-018](medium/BUG-018-missing-commands.md) | Missing slash command handlers | CLI Commands | Open |

### UX Issues (5)

| ID | Title | Component | Status |
|---|---|---|---|
| [UX-001](ux/UX-001-no-api-key-feedback.md) | No API key detection feedback | Onboarding | Open |
| [UX-002](ux/UX-002-retry-star-broken.md) | Retry/star button not working | Desktop App | Open |
| [UX-003](ux/UX-003-ollama-not-selectable.md) | Ollama not showing as selectable | Desktop App | Open |
| [UX-004](ux/UX-004-desktop-ux-issues.md) | General desktop UX issues | Desktop App | Open |
| [UX-005](ux/UX-005-port-mismatch.md) | Port mismatch 8089 vs 9089 | Desktop/Backend | Resolved (both now 9089) |

### Fixed (4)

| ID | Title | Fixed In |
|---|---|---|
| [BUG-001](fixed/BUG-001-onboarding-crash.md) | Onboarding selector crash | v0.2.5 |
| [BUG-002](fixed/BUG-002-signal-classified-missing.md) | Events.Bus missing :signal_classified | v0.2.5 |
| [BUG-003](fixed/BUG-003-groq-tool-call-id.md) | Groq tool_call_id missing | v0.2.5 |
| [BUG-004-partial](fixed/BUG-004-partial-llama32.md) | llama3.2 added to tool_capable_prefixes | v0.2.6 |

---

## By Component

| Component | Issues | Critical |
|---|---|---|
| Agent Loop / Tool Execution | BUG-004, BUG-005, BUG-009 | 2 |
| Security | BUG-017 | 1 |
| HTTP Router | BUG-011, BUG-012 | 0 |
| CLI Commands | BUG-008, BUG-018 | 0 |
| Provider System | BUG-007 | 0 |
| Noise Filter | BUG-006 | 0 |
| Data Storage | BUG-016 | 0 |
| Swarm System | BUG-015 | 0 |
| Health/Monitoring | BUG-010 | 0 |
| Desktop App | UX-001 through UX-005 | 0 |

---

## Contributing

When filing a new issue:
1. Copy [TEMPLATE.md](TEMPLATE.md)
2. Place in the appropriate severity directory
3. Name the file `BUG-NNN-short-description.md` or `UX-NNN-short-description.md`
4. Add an entry to this README's index
5. Include reproduction steps if possible
