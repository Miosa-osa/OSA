---
name: prime-miosa
description: Load MIOSA platform development context
---

# Prime: MIOSA Platform Development

## Architecture Overview
```
┌─────────────────────────────────────────┐
│           User Interface                │
│    (BusinessOS - Svelte, OSA - React)   │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│         Stable Orchestrator             │
│         (Go - Agent Coordination)       │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│         Consultation Server             │
│         (Go - User Interaction)         │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│           E2B Sandbox                   │
│         (Code Execution)                │
└─────────────────────────────────────────┘
```

## Key Services
- **stable-orchestrator**: Agent routing and coordination
- **consultation-server**: User session management
- **E2B Bridge**: Sandbox management via Abdul's integration

## Development Workflow
1. Check existing patterns in codebase
2. Coordinate with team (Pedro-backend, Abdul-E2B)
3. Test with E2B sandbox
4. Document architectural decisions

## Deployments
- GCP Cloud Run for services
- Cloud SQL PostgreSQL
- SSE for real-time streaming
