# Example: SaaS Dashboard — Performance + Security Sprint

> Fictional project management SaaS. Python + FastAPI + PostgreSQL + React + TypeScript.

Demonstrates:
- **P0 critical escalation** — IDOR vulnerability is P0 (security), triggers immediate focus
- **Context density** — dashboard endpoint has highest density (847 queries = root cause)
- **Chain execution** across security findings (each OWASP item is a separate chain)
- **Cross-layer traces** — XSS chain goes from API (no sanitization) through DB (stored) to frontend (rendered unsafely)
- **DATA** fixing the query layer before SERVICES adds caching (cache on top of a broken query is still broken)
- **QA** writing security regression tests that validate every fix
