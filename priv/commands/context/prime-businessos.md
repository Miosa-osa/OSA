---
name: prime-businessos
description: Load BusinessOS platform development context
---

# Prime: BusinessOS Platform

## Architecture
```
┌─────────────────────────────────────────┐
│        BusinessOS Frontend              │
│        (Svelte/SvelteKit)               │
└─────────────────┬───────────────────────┘
                  │ SSE
┌─────────────────▼───────────────────────┐
│        BusinessOS Backend               │
│        (Go - stable-orchestrator)       │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│        AI Agent System                  │
│        (22+ specialized agents)         │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│        E2B Sandbox                      │
│        (Code execution)                 │
└─────────────────────────────────────────┘
```

## Key Locations
- Frontend: ~/Desktop/BusinessOS/frontend/
- Backend: ~/Desktop/BusinessOS/backend/
- Desktop App: ~/Desktop/BusinessOS/desktop/

## Agent Routing for BusinessOS
- Frontend work → businessos-frontend
- Backend work → businessos-backend
- E2B integration → e2b-specialist
- SSE streaming → sse-specialist

## Team Context
- Roberto: Architecture, coordination
- Pedro: Backend, consultation server
- Abdul: E2B integration
- Nick: Terminal, GCP

Ready for BusinessOS development.
