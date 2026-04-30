# Example: E-Commerce API — Payment Bug Fix Sprint

> Fictional e-commerce platform. Go + Chi + PostgreSQL + Stripe + React.

Demonstrates:
- **Execution traces** tracing payment bugs from HTTP entry to database root cause
- **Chain execution** — complete one payment bug end-to-end before starting the next
- **P1 priority** on all payment-related chains (money is involved)
- **DATA** fixing data layer (mutex, transactions) before BACKEND fixes handlers
- **SERVICES** hardening the Stripe integration (idempotency keys)
- **FRONTEND** adding frontend safety (loading states, double-click prevention)
