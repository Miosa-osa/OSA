# Agent F — DATA: Data Layer

> Sprint 01 | Payment Bug Fix + Checkout Hardening
> Stack: Go + PostgreSQL
> Branch: `sprint-01/data`

## Mission

Fix the order store mutex issue causing webhook timeouts, add database transactions to checkout flow to prevent double charges, and ensure all payment state mutations are atomic.

## Chains

### Chain 1: Webhook Timeout — Store Layer (P1)
**Vector:** `orderStore.MarkPaid()` holds write lock → calls `notificationService.SendReceipt()` (HTTP call under mutex) → 30s timeout

**Trace:**
1. Read `internal/store/order.go` — find `MarkPaid()` method
2. Identify: mutex is held during the entire method body
3. The notification call is INSIDE the lock scope

**Fix:** Release mutex before notification. Split into: `markPaidInDB()` (under lock) + `sendReceipt()` (after lock release).

**Verify:** Webhook responds in <2s. No race on concurrent `MarkPaid()` calls.

### Chain 2: Double Charge — Idempotency at Store Level (P1)
**Vector:** Two goroutines call `orderStore.CreateOrder()` with same cart → both succeed → two Stripe charges

**Trace:**
1. Read `internal/store/order.go` — find `CreateOrder()`
2. No uniqueness check on cart_id before insert
3. No database transaction wrapping the check + insert

**Fix:** Add unique constraint on `cart_id` in orders table. Wrap `CreateOrder()` in a DB transaction with `SELECT ... FOR UPDATE` on cart.

**Verify:** `INSERT` with duplicate cart_id returns conflict error. Concurrent test passes.

## Territory

**Can modify:**
- `internal/store/*.go`
- `internal/model/*.go`
- `migrations/`

**Read-only:** handlers, services, Stripe client, frontend

## Acceptance Criteria

- [ ] `MarkPaid()` releases lock before any I/O
- [ ] `CreateOrder()` uses DB transaction with cart uniqueness
- [ ] All store methods audited for I/O under mutex
- [ ] Migration script for cart_id unique constraint
- [ ] `go test -race ./internal/store/...` passes
