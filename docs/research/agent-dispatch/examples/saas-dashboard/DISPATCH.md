# Sprint 02 Dispatch — Performance + Security Hardening

> Fix dashboard load time (12s → <2s), close OWASP findings, add auth
> Stack: Python + FastAPI + PostgreSQL + React + TypeScript

## Sprint Goals

1. Fix dashboard loading 12s (N+1 queries, no pagination, no caching)
2. Close 4 OWASP findings from pen test (IDOR, missing auth, XSS, SSRF)
3. Add JWT authentication to all API endpoints
4. Establish performance baseline metrics

## Execution Traces

### Chain 1: Dashboard N+1 Query (P1)
```
GET /api/dashboard → dashboardRouter.get_summary()
→ projectService.list_all() → FOR EACH project: taskService.count_by_project()
Signal: 847 SQL queries for 200 projects. Each project triggers a separate COUNT.
```

### Chain 2: IDOR on Project Endpoints (P0 — Security)
```
GET /api/projects/:id → projectRouter.get()
→ projectService.get_by_id(id) — NO ownership check
Signal: Any user can access any project by guessing UUID.
```

### Chain 3: XSS in Project Names (P1 — Security)
```
POST /api/projects → projectRouter.create(name=<script>...)
→ projectStore.create() → stored unsanitized
→ GET /api/projects → rendered in React dangerouslySetInnerHTML
Signal: Stored XSS. Script executes for all team members viewing project list.
```

### Chain 4: SSRF via Webhook URL (P1 — Security)
```
POST /api/integrations/webhook → integrationRouter.create(url=http://169.254.169.254/...)
→ webhookService.test_connection(url) → httpx.get(url)
Signal: No URL validation. Can reach AWS metadata endpoint.
```

## Wave Assignments

### Wave 1 — Foundation

| Agent | Focus | Chains |
|-------|-------|--------|
| DATA | Fix N+1 with JOIN query, add pagination to list endpoints | Chain 1 |
| QA | OWASP validation tests, auth integration tests | Chain 2, 3, 4 |
| INFRA | Add rate limiting middleware, security headers | Support all chains |

### Wave 2 — Backend

| Agent | Focus | Chains |
|-------|-------|--------|
| BACKEND | Add JWT auth middleware, ownership checks, input sanitization, URL validation | Chain 2, 3, 4 |
| SERVICES | Add Redis caching for dashboard aggregates | Chain 1 (caching layer) |

### Wave 3 — Frontend

| Agent | Focus | Chains |
|-------|-------|--------|
| FRONTEND | Remove dangerouslySetInnerHTML, add loading skeletons, paginated tables | Chain 1, 3 |

## Merge Order

```
1. DATA → main  (query fix + pagination)
2. BACKEND   → main  (auth + security fixes)
3. SERVICES   → main  (caching layer)
4. FRONTEND   → main  (frontend safety + performance)
5. INFRA → main  (rate limiting + headers)
6. QA    → main  (security tests validate everything)
```

## Success Criteria

- [ ] Dashboard loads in <2s (was 12s)
- [ ] SQL queries per dashboard request: <10 (was 847)
- [ ] All 4 OWASP findings closed and verified with tests
- [ ] JWT auth on every endpoint (401 without token)
- [ ] No XSS possible in any user input field
- [ ] SSRF blocked (URL allowlist enforced)
- [ ] Performance baseline documented (p50, p95, p99 latency)
