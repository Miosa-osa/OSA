# Sprint 01 Dispatch — Payment Bug Fix + Checkout Hardening

> Fix payment processing failures, harden checkout flow, establish test baseline
> Stack: Go + Chi + PostgreSQL + Stripe + React frontend

## Sprint Goals

1. Fix 3 critical payment bugs (webhook timeout, double charge, failed refund)
2. Harden checkout flow error handling
3. Add database transaction safety to order creation
4. Establish test coverage for payment critical path

## Execution Traces

### Chain 1: Webhook Timeout (P1)
```
POST /webhooks/stripe → webhookHandler.ProcessEvent()
→ paymentService.HandleInvoicePaid() → orderStore.MarkPaid()
→ notificationService.SendReceipt()
Signal: 504 timeout after 30s. I/O under mutex in orderStore.
```

### Chain 2: Double Charge (P1)
```
POST /api/checkout → checkoutHandler.Create()
→ paymentService.ChargeCard() → stripe.Charges.Create()
Signal: Race condition — two goroutines process same cart simultaneously.
No idempotency key on Stripe call.
```

### Chain 3: Failed Refund (P1)
```
POST /api/orders/:id/refund → orderHandler.Refund()
→ paymentService.ProcessRefund() → stripe.Refunds.Create()
Signal: Refund succeeds at Stripe but orderStore.UpdateStatus() fails.
Order stuck in "refunding" state forever.
```

## Wave Assignments

### Wave 1 — Foundation

| Agent | Focus | Chains |
|-------|-------|--------|
| DATA | Fix orderStore mutex issue, add DB transactions | Chain 1 (store layer), Chain 2 (idempotency) |
| QA | Write payment flow tests, scan Stripe SDK for CVEs | All chains (test coverage) |

### Wave 2 — Backend

| Agent | Focus | Chains |
|-------|-------|--------|
| BACKEND | Fix webhook handler timeout, refund status sync | Chain 1, Chain 3 |
| SERVICES | Add Stripe idempotency keys, retry logic | Chain 2 |

### Wave 3 — Frontend

| Agent | Focus | Chains |
|-------|-------|--------|
| FRONTEND | Add checkout loading states, error recovery UI, disable double-click | Chain 2 (frontend) |

## Merge Order

```
1. DATA → main  (store transactions + mutex fix)
2. BACKEND   → main  (handler fixes)
3. SERVICES   → main  (Stripe client hardening)
4. FRONTEND   → main  (checkout UI)
5. QA    → main  (tests validate everything)
```

## Success Criteria

- [ ] Zero webhook timeouts (test with Stripe CLI: `stripe trigger invoice.paid`)
- [ ] Zero double charges (load test: 10 concurrent checkout requests, same cart)
- [ ] Refund status always consistent between Stripe and DB
- [ ] Checkout UI shows loading state, prevents double-click
- [ ] 80%+ test coverage on payment critical path
